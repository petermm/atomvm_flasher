#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.4.0"},
  {:jason, "~> 1.4"},
  {:ymlr, "~> 3.0"},
  {:uf2tool, "1.1.0"}
])

Code.require_file(Path.expand("atomvm_releases_fetcher.exs", __DIR__))

AtomVMReleasesFetcher.main()
