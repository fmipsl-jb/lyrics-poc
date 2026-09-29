"""
app.py — Tkinter GUI for the Lyrics PoC.

Workflow (mirrors the PRD):
  1. Choose an audio file.
  2. Hit "Scan".
  3. Watch a progress bar while Whisper transcribes.
  4. See a human-readable success or error message.
  5. On success, save the timecoded lyrics as a .md file to a chosen directory.

Design notes:
  - Tkinter is used because it ships with Python on both macOS and Windows,
    keeping the app dependency-light and genuinely cross-platform.
  - Transcription runs on a background thread; the model download + decoding can
    take a while and must not freeze the UI. Cross-thread updates are marshalled
    back onto the Tk main loop via a thread-safe queue polled by `after()`.
"""

from __future__ import annotations

import os
import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import transcriber


# Model choice for the PoC. "base" balances speed, download size, and quality.
DEFAULT_MODEL = "base"

# Audio file types offered in the picker. Whisper (via ffmpeg) handles many more;
# this is just the friendly shortlist for the dialog.
AUDIO_FILETYPES = [
    ("Audio files", "*.wav *.mp3 *.m4a *.flac *.ogg *.aac *.wma *.aiff"),
    ("All files", "*.*"),
]


class LyricsApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Lyrics — Transcription PoC")
        self.minsize(560, 320)

        # State
        self._audio_path: str | None = None
        self._result_markdown: str | None = None
        self._ui_queue: "queue.Queue[tuple]" = queue.Queue()

        self._build_ui()
        self._poll_queue()

        # Ensure the window paints immediately. On some macOS Tk builds the
        # content can appear blank until the first geometry/redraw cycle; forcing
        # it here avoids an empty white window on launch.
        self.update_idletasks()
        self.deiconify()
        self.lift()
        self.focus_force()

    # --- UI construction ---------------------------------------------------

    def _build_ui(self) -> None:
        pad = {"padx": 12, "pady": 8}

        container = ttk.Frame(self)
        container.pack(fill="both", expand=True)
        container.columnconfigure(0, weight=1)

        # File selection row
        file_frame = ttk.LabelFrame(container, text="1. Choose an audio file")
        file_frame.grid(row=0, column=0, sticky="ew", **pad)
        file_frame.columnconfigure(0, weight=1)

        self._file_label = ttk.Label(
            file_frame, text="No file selected.", anchor="w"
        )
        self._file_label.grid(row=0, column=0, sticky="ew", padx=8, pady=8)

        self._choose_btn = ttk.Button(
            file_frame, text="Choose file…", command=self._on_choose_file
        )
        self._choose_btn.grid(row=0, column=1, padx=8, pady=8)

        # Scan row
        scan_frame = ttk.LabelFrame(container, text="2. Transcribe")
        scan_frame.grid(row=1, column=0, sticky="ew", **pad)
        scan_frame.columnconfigure(0, weight=1)

        self._scan_btn = ttk.Button(
            scan_frame, text="Scan", command=self._on_scan, state="disabled"
        )
        self._scan_btn.grid(row=0, column=0, sticky="w", padx=8, pady=8)

        self._progress = ttk.Progressbar(
            scan_frame, orient="horizontal", mode="determinate", maximum=100
        )
        self._progress.grid(row=1, column=0, sticky="ew", padx=8, pady=(0, 8))

        self._status_label = ttk.Label(scan_frame, text="Idle.", anchor="w")
        self._status_label.grid(row=2, column=0, sticky="ew", padx=8, pady=(0, 8))

        # Save row
        save_frame = ttk.LabelFrame(container, text="3. Save lyrics (.md)")
        save_frame.grid(row=2, column=0, sticky="ew", **pad)
        save_frame.columnconfigure(0, weight=1)

        self._save_btn = ttk.Button(
            save_frame,
            text="Save lyrics as .md…",
            command=self._on_save,
            state="disabled",
        )
        self._save_btn.grid(row=0, column=0, sticky="w", padx=8, pady=8)

    # --- Event handlers ----------------------------------------------------

    def _on_choose_file(self) -> None:
        path = filedialog.askopenfilename(
            title="Choose an audio file", filetypes=AUDIO_FILETYPES
        )
        if not path:
            return
        self._audio_path = path
        self._file_label.config(text=path)
        self._scan_btn.config(state="normal")
        self._save_btn.config(state="disabled")
        self._result_markdown = None
        self._progress["value"] = 0
        self._status_label.config(text="Ready to scan.")

    def _on_scan(self) -> None:
        if not self._audio_path:
            return

        # Verify dependencies up front and explain clearly if something's missing.
        status = transcriber.check_dependencies()
        if not status.ok:
            messagebox.showerror("Setup needed", status.message)
            return

        # Lock the UI while working.
        self._set_working(True)
        self._progress["value"] = 0
        self._status_label.config(text="Loading model and transcribing…")

        thread = threading.Thread(target=self._run_transcription, daemon=True)
        thread.start()

    def _on_save(self) -> None:
        if not self._result_markdown:
            return

        suggested = "lyrics.md"
        if self._audio_path:
            base = os.path.splitext(os.path.basename(self._audio_path))[0]
            suggested = f"{base}.lyrics.md"

        path = filedialog.asksaveasfilename(
            title="Save lyrics as Markdown",
            defaultextension=".md",
            initialfile=suggested,
            filetypes=[("Markdown", "*.md"), ("All files", "*.*")],
        )
        if not path:
            return

        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(self._result_markdown)
        except OSError as exc:
            messagebox.showerror(
                "Could not save file",
                f"The lyrics could not be saved to:\n{path}\n\nReason: {exc}",
            )
            return

        messagebox.showinfo("Saved", f"Lyrics saved to:\n{path}")

    # --- Background work ---------------------------------------------------

    def _run_transcription(self) -> None:
        """Runs on a worker thread. Communicates back via self._ui_queue."""
        try:
            def progress_cb(frac: float) -> None:
                self._ui_queue.put(("progress", frac))

            result = transcriber.transcribe(
                self._audio_path,
                model_name=DEFAULT_MODEL,
                progress_cb=progress_cb,
            )
            self._ui_queue.put(("done", result))
        except FileNotFoundError as exc:
            self._ui_queue.put(("error", f"The audio file could not be found.\n\n{exc}"))
        except RuntimeError as exc:
            self._ui_queue.put(("error", str(exc)))
        except Exception as exc:  # last-resort catch-all, still human-readable
            self._ui_queue.put(
                ("error", f"An unexpected error occurred during transcription.\n\n{exc}")
            )

    # --- Thread-safe UI updates -------------------------------------------

    def _poll_queue(self) -> None:
        try:
            while True:
                kind, payload = self._ui_queue.get_nowait()
                if kind == "progress":
                    self._progress["value"] = int(payload * 100)
                    self._status_label.config(
                        text=f"Transcribing… {int(payload * 100)}%"
                    )
                elif kind == "done":
                    self._handle_done(payload)
                elif kind == "error":
                    self._handle_error(payload)
        except queue.Empty:
            pass
        finally:
            # Poll again shortly; keeps the UI responsive without busy-waiting.
            self.after(100, self._poll_queue)

    def _handle_done(self, result: dict) -> None:
        self._set_working(False)
        self._progress["value"] = 100
        self._result_markdown = result["markdown"]
        count = result["segment_count"]
        lang = result["language"]
        self._status_label.config(text="Done.")
        self._save_btn.config(state="normal")

        if count == 0:
            messagebox.showwarning(
                "Finished — but nothing to show",
                "Transcription finished, but no speech or lyrics were detected "
                "in this audio file.\n\nYou can still save the (empty) result.",
            )
        else:
            messagebox.showinfo(
                "Transcription complete",
                f"Success! Transcribed {count} timecoded line(s).\n"
                f"Detected language: {lang}.\n\n"
                "Click “Save lyrics as .md…” to save the result where you like.",
            )

    def _handle_error(self, message: str) -> None:
        self._set_working(False)
        self._progress["value"] = 0
        self._status_label.config(text="Error.")
        messagebox.showerror("Transcription failed", message)

    def _set_working(self, working: bool) -> None:
        state = "disabled" if working else "normal"
        self._choose_btn.config(state=state)
        self._scan_btn.config(state=state)


def main() -> None:
    app = LyricsApp()
    app.mainloop()


if __name__ == "__main__":
    main()
