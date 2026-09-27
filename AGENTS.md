# Project workflow

When the user asks to make changes on this project, complete the whole workflow:

1. Implement the changes.
2. Run the relevant automated tests and actual WPF integration checks.
3. Update all affected documentation.
4. Regenerate every documented application screenshot from the updated real UI with isolated fixture data; inspect the results.
5. Commit and push the changes to the repository.

Preserve unrelated local changes, especially the user's `config.json` and untracked artwork. Do not include personal corpus data in commits or screenshots. Use Windows PowerShell 5.1 for this Windows/WPF app. Run integrations that own dependency locks sequentially.
