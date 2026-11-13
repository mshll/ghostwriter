Faster suggestions, stronger privacy, and Ghostwriter now learns only from what you type.

- **Coming from Cotypist?** Import your recorded writing, instructions and per-app settings during setup or from Settings > Personalization.
- **Models already on your Mac.** A model from the Hugging Face cache, llama.cpp, LM Studio or Ollama is linked instead of downloaded again. Other base models found there are listed in Settings > Model.
- **Payment and one-time code fields.** Card number, security code, expiry and one-time code fields are never read or recorded.
- **Off everywhere means off.** While suggestions are off everywhere, nothing is read or recorded and the model is unloaded to free memory.
- **Learns only your writing.** Accepted suggestions, typo fixes, proofreads and emoji are no longer stored as your writing. Short chat messages are kept. Old copies of the text you edit are no longer used as examples. Erasing your writing also drops what was about to be saved.
- **Faster.** Less work on each key press, no stall every sentence in long documents, quicker suggestions in the middle of a line, and no delay on the first suggestion after the model loads.
- **Less work when idle.** Background checks slow down when nothing changes and stop while the Mac or its displays sleep.
- **Downloads resume.** A model download stopped by quitting continues at the next launch, however much later.
- **Fixes:**
  - Tab and other accept keys no longer act in an app you just left.
  - Return hides the suggestion.
  - Suggestions and popups no longer cover text where an app does not report the cursor position.
  - Contractions such as "doesn't" are no longer flagged as typos.
  - Short text is no longer detected as the wrong language.
  - Reset all settings keeps your words not flagged and your chosen model.

Requires macOS 26 or later on Apple silicon.
