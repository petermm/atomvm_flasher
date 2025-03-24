#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.4.0"},
  {:jason, "~> 1.4"},
  {:ymlr, "~> 3.0"}
])

defmodule AtomVMReleasesFetcher do
  @config %{
    owner: "atomvm",
    repo: "atomvm",
    assets_dir: "assets/release_binaries",
    token: System.get_env("GITHUB_TOKEN") || System.get_env("GH_TOKEN")
  }

  @firmware_regex ~r/^AtomVM-esp32(?:[cp][2-6]|s[23])?(?:-elixir)?-v\d+\.\d+\.\d+\.img$/

  def main do
    ensure_assets_dir()
    releases = fetch_releases()
    IO.puts("Found #{length(releases)} releases")

    # Filter releases by date
    cutoff_date = "2021-03-05T17:33:14Z" |> DateTime.from_iso8601() |> elem(1)

    recent_releases =
      Enum.filter(releases, fn release ->
        {:ok, published_at, _} = DateTime.from_iso8601(release["published_at"])
        DateTime.compare(published_at, cutoff_date) == :gt
      end)

    versions_data = %{
      "versions" =>
        Enum.map(recent_releases, fn release ->
          has_elixir_assets =
            Enum.any?(release["assets"], fn asset ->
              Regex.match?(
                ~r/^AtomVM-esp32(?:[cp][2-6]|s[23])?-elixir-v\d+\.\d+\.\d+\.img$/,
                asset["name"]
              )
            end)

          supported_boards = get_supported_boards(release["assets"])

          %{
            "version" => release["tag_name"],
            "published_at" => release["published_at"],
            "html_url" => release["html_url"],
            "has_elixir" => has_elixir_assets,
            "supported_boards" => Enum.sort(supported_boards)
          }
        end)
    }

    # Write versions.json
    versions_json_path = Path.join(@config.assets_dir, "versions.json")
    IO.puts("Writing versions data to #{versions_json_path}")
    File.write!(versions_json_path, Jason.encode!(versions_data, pretty: true))

    # Write versions.yml
    versions_yml_path = Path.join("_data", "versions.yml")
    IO.puts("Writing versions data to #{versions_yml_path}")
    File.write!(versions_yml_path, Ymlr.document!(versions_data))

    # Process each release
    Enum.each(releases, fn release ->
      assets = Enum.filter(release["assets"], &Regex.match?(@firmware_regex, &1["name"]))
      IO.puts("Processing release #{release["tag_name"]}")
      IO.puts("Found #{length(assets)} matching firmware assets")

      if length(assets) > 0 do
        tag_dir = Path.join(@config.assets_dir, release["tag_name"])
        File.mkdir_p!(tag_dir)

        {standard_assets, elixir_assets} =
          Enum.split_with(assets, &(!String.contains?(&1["name"], "-elixir-")))

        # Create and write standard release data
        standard_release_data = create_release_data(release, standard_assets)
        standard_json_path = Path.join(tag_dir, "release.json")
        IO.puts("Writing standard release data to #{standard_json_path}")
        File.write!(standard_json_path, Jason.encode!(standard_release_data, pretty: true))

        # Create and write elixir release data if available
        if length(elixir_assets) > 0 do
          elixir_release_data = create_release_data(release, elixir_assets)
          elixir_json_path = Path.join(tag_dir, "release-elixir.json")
          IO.puts("Writing elixir release data to #{elixir_json_path}")
          File.write!(elixir_json_path, Jason.encode!(elixir_release_data, pretty: true))
        end

        # Download assets
        Enum.each(assets, fn asset ->
          asset_path = Path.join(tag_dir, asset["name"])
          download_asset(asset, asset_path)
        end)
      end
    end)

    IO.puts("Release fetching completed successfully!")
  end

  defp ensure_assets_dir do
    unless File.exists?(@config.assets_dir) do
      IO.puts("Creating assets directory: #{@config.assets_dir}")
      File.mkdir_p!(@config.assets_dir)
    end
  end

  defp fetch_releases do
    IO.puts("Fetching releases from atomvm/atomvm repository...")

    headers = [
      # {"Authorization", "token #{@config.token}"},
      {"Accept", "application/vnd.github.v3+json"},
      {"User-Agent", "AtomVM-Releases-Fetcher"}
    ]

    case Req.get!(
           "https://api.github.com/repos/#{@config.owner}/#{@config.repo}/releases?per_page=100",
           headers: headers
         ) do
      %{status: 200, body: body} ->
        body

      %{status: 403} = resp ->
        case get_in(resp.headers, ["x-ratelimit-remaining"]) do
          "0" ->
            reset_time =
              get_in(resp.headers, ["x-ratelimit-reset"])
              |> String.to_integer()
              |> DateTime.from_unix!()
              |> DateTime.to_string()

            raise "GitHub API rate limit exceeded. Resets at #{reset_time}"

          _ ->
            raise "GitHub API access denied. Please ensure you have a valid GITHUB_TOKEN environment variable set."
        end

      resp ->
        raise "Failed to fetch releases: #{inspect(resp)}"
    end
  end

  defp download_asset(asset, asset_path) do
    if File.exists?(asset_path) do
      %{size: existing_size} = File.stat!(asset_path)

      if existing_size == asset["size"] do
        IO.puts("Asset #{asset["name"]} already exists with correct size, skipping download")
        :ok
      else
        do_download_asset(asset, asset_path)
      end
    else
      do_download_asset(asset, asset_path)
    end
  end

  defp do_download_asset(asset, asset_path) do
    IO.puts(
      "Downloading asset: #{asset["name"]} (#{Float.round(asset["size"] / 1024 / 1024, 2)} MB)"
    )

    headers = [
      # {"Authorization", "token #{@config.token}"},
      {"Accept", "application/octet-stream"},
      {"User-Agent", "AtomVM-Releases-Fetcher"}
    ]

    case Req.get!(asset["browser_download_url"], headers: headers) do
      %{status: 200, body: body} ->
        File.write!(asset_path, body)
        IO.puts("Successfully saved asset to #{asset_path}")

      resp ->
        File.rm(asset_path)
        raise "Failed to download asset: #{inspect(resp)}"
    end
  end

  defp get_supported_boards(assets) do
    Enum.reduce(assets, MapSet.new(), fn asset, acc ->
      cond do
        String.match?(asset["name"], ~r/^AtomVM-esp32p4-/) -> MapSet.put(acc, "ESP32-P4")
        String.match?(asset["name"], ~r/^AtomVM-esp32c5-/) -> MapSet.put(acc, "ESP32-C5")
        String.match?(asset["name"], ~r/^AtomVM-esp32c6-/) -> MapSet.put(acc, "ESP32-C6")
        String.match?(asset["name"], ~r/^AtomVM-esp32c3-/) -> MapSet.put(acc, "ESP32-C3")
        String.match?(asset["name"], ~r/^AtomVM-esp32c2-/) -> MapSet.put(acc, "ESP32-C2")
        String.match?(asset["name"], ~r/^AtomVM-esp32s3-/) -> MapSet.put(acc, "ESP32-S3")
        String.match?(asset["name"], ~r/^AtomVM-esp32s2-/) -> MapSet.put(acc, "ESP32-S2")
        String.match?(asset["name"], ~r/^AtomVM-esp32h2-/) -> MapSet.put(acc, "ESP32-H2")
        String.match?(asset["name"], ~r/^AtomVM-esp32-/) -> MapSet.put(acc, "ESP32")
        true -> acc
      end
    end)
  end

  defp create_release_data(release, assets) do
    %{
      "name" => "AtomVM",
      "version" => release["tag_name"],
      "published_at" => release["published_at"],
      "html_url" => release["html_url"],
      "new_install_prompt_erase" => true,
      "new_install_improv_wait_time" => 0,
      "builds" =>
        Enum.map(assets, fn asset ->
          %{
            "chipFamily" => get_chip_family(asset["name"]),
            "parts" => [
              %{
                "path" => "#{asset["name"]}",
                "offset" => get_offset(asset["name"])
              }
            ]
          }
        end)
    }
  end

  def get_chip_family(name) do
    cond do
      String.match?(name, ~r/^atomvm-esp32p4-/i) -> "ESP32-P4"
      String.match?(name, ~r/^atomvm-esp32c6-/i) -> "ESP32-C6"
      String.match?(name, ~r/^atomvm-esp32c3-/i) -> "ESP32-C3"
      String.match?(name, ~r/^atomvm-esp32c2-/i) -> "ESP32-C2"
      String.match?(name, ~r/^atomvm-esp32s3-/i) -> "ESP32-S3"
      String.match?(name, ~r/^atomvm-esp32s2-/i) -> "ESP32-S2"
      String.match?(name, ~r/^atomvm-esp32h2-/i) -> "ESP32-H2"
      String.match?(name, ~r/^atomvm-esp32-/i) -> "ESP32"
      true -> "UNKNOWN"
    end
  end

  def get_offset(name) do
    cond do
      String.match?(name, ~r/^atomvm-esp32p4-/i) -> 8192
      String.match?(name, ~r/^atomvm-esp32-/i) -> 4096
      String.match?(name, ~r/^atomvm-esp32s2-/i) -> 4096
      true -> 0
    end
  end
end

AtomVMReleasesFetcher.main()
