# Contributing

Thanks for helping out! KanbanEasy is a small MIT-licensed project and contributions of any size are welcome.

- **Bugs and ideas:** open an [issue](../../issues). For bugs, include your OS and what you expected to happen.
- **Pull requests:** fork, branch, and open a PR against `main`. Keep changes focused.
- **Before you push**, make sure these pass (CI runs them too):

  ```sh
  busted            # unit tests
  luacheck .        # lint
  stylua .          # format
  ```

- See [docs/BUILDING.md](docs/BUILDING.md) for running from source and the code layout.

By contributing you agree that your work is released under the [MIT License](LICENSE).
