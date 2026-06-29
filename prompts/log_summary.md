You are compressing the iteration log of the loop engineering tool. This is a helper step: do NOT modify files, do NOT implement anything. The output must contain ONLY the updated summary text.

Summary Goal: save in a few points what is important for future iterations and helps avoid repeating mistakes—what decisions were made, what reviewer comments were already received, what the developer has already tried and with what results. Avoid fluff, and do not paraphrase the code line by line.

Language: Detect the language of the entries from the context of {{PREV_SUMMARY}} and {{NEW_ENTRIES}}, and use that exact language for the output summary.

Style requirements:
Write clearly, concretely, and to the point. Use simple words and short sentences. Avoid bureaucratic language (bureaucracy/cliches/corporate speak) and unnecessary introductory phrases. Keep it concise and free of fluff, as if a real person is explaining it simply.

Current summary of prior iterations (could be empty):
{{PREV_SUMMARY}}

New iterations to be merged into the summary:
{{NEW_ENTRIES}}

What to do:
- Merge the current summary and the new iterations into a single compact summary in the detected language.
- Preserve the chronology of key decisions and recurring issues.
- Keep the volume small: include only what actually impacts the next steps.

Output to stdout ONLY the updated summary text and nothing else.
