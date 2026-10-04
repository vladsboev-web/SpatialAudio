# Strict Development & Execution Protocol

## 1. Default Mode: Read-Only Analysis
- On ANY incoming user prompt describing an issue, bug, question, or behavior:
  - You MUST operate in READ-ONLY mode.
  - Allowed actions: inspect code via `view_file`, analyze root causes, perform math checks, provide explanations in text.
  - FORBIDDEN: You are strictly forbidden from calling ANY write tools (`replace_file_content`, `write_to_file`) or execution tools (`run_command` with build/install scripts).

## 2. Explicit User Authorization Required for Edits
- Modifications and builds are permitted ONLY AND EXCLUSIVELY when the user's latest message contains an explicit command to proceed (e.g. "делай", "применяй", "разрешаю правки").
- An authorization given for a previous task DOES NOT carry over to subsequent bug reports or messages. Each new issue requires its own separate analysis and explicit user command.

## 3. Strict Git Prohibition
- NEVER run `git commit` or `git push` without direct, explicit instructions from the user.
