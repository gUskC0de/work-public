# Documentation maintenance

- `ANVANDARGUIDE.md` is the source for the Swedish operator guide.
- Whenever the guide changes, run `python3 tools/export_user_guide.py` and include
  the updated `ANVANDARGUIDE.txt` in the same change. Do not edit the TXT
  mirror directly.
- Verify the mirror with `python3 tools/export_user_guide.py --check`.
- Keep the TXT mirror in UTF-8 with BOM and CRLF line endings for Windows Notepad.
