#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.4.0"},
  {:jason, "~> 1.4"},
  {:ymlr, "~> 3.0"},
  {:uf2tool, "1.1.0"}
])

defmodule AtomVMReleasesFetcher do
  @moduledoc """
  Fetches AtomVM releases from GitHub and processes their assets.
  Generates metadata files and downloads firmware binaries.
  """

  @config %{
    owner: "atomvm",
    repo: "atomvm",
    assets_dir: "assets/release_binaries"
  }

  @cutoff_date "2023-10-14T00:37:40Z"

  # Asset pattern matching
  @esp32_firmware_regex ~r/^AtomVM-esp32(?:[cp][2-6]|s[23])?(?:-elixir)?-v\d+\.\d+\.\d+\.img$/
  @esp32_elixir_regex ~r/^AtomVM-esp32(?:[cp][2-6]|s[23])?-elixir-v\d+\.\d+\.\d+\.img$/
  @pico_firmware_regex ~r/^AtomVM-pico(?:_w)?-v\d+\.\d+\.\d+\.uf2$/
  @pico_atomvmlib_regex ~r/^atomvmlib-v\d+\.\d+\.\d+\.uf2$/

  # Chip family detection patterns
  @chip_families [
    {~r/esp32p4/i, "ESP32-P4"},
    {~r/esp32c61/i, "ESP32-C61"},
    {~r/esp32c6/i, "ESP32-C6"},
    {~r/esp32c5/i, "ESP32-C5"},
    {~r/esp32c3/i, "ESP32-C3"},
    {~r/esp32c2/i, "ESP32-C2"},
    {~r/esp32s3/i, "ESP32-S3"},
    {~r/esp32s2/i, "ESP32-S2"},
    {~r/esp32h2/i, "ESP32-H2"},
    {~r/esp32-/i, "ESP32"}
  ]

  @doc """
  Main entry point for the script
  """
  def main do
    ensure_assets_dir()

    releases =
      fetch_releases()
      |> filter_recent_releases()

    IO.puts("Found #{length(releases)} recent releases")

    # Generate and write version data
    write_version_data(releases)

    # Process releases
    Enum.each(releases, fn release ->
      process_pico_release(release)
      process_esp32_release(release)
    end)

    IO.puts("Release fetching completed successfully!")
  end

  @doc """
  Ensures the assets directory exists
  """
  defp ensure_assets_dir do
    unless File.exists?(@config.assets_dir) do
      IO.puts("Creating assets directory: #{@config.assets_dir}")
      File.mkdir_p!(@config.assets_dir)
    end
  end

  @doc """
  Fetches all releases from GitHub
  """
  defp fetch_releases do
    IO.puts("Fetching releases from #{@config.owner}/#{@config.repo} repository...")

    headers = [
      {"Accept", "application/vnd.github.v3+json"},
      {"User-Agent", "AtomVM-Releases-Fetcher"}
    ]

    case Req.get!(
           "https://api.github.com/repos/#{@config.owner}/#{@config.repo}/releases?per_page=100",
           headers: headers
         ) do
      %{status: 200, body: body} ->
        body

      %{status: 403, headers: headers} = resp ->
        handle_rate_limit_error(headers, resp)

      resp ->
        raise "Failed to fetch releases: #{inspect(resp)}"
    end
  end

  @doc """
  Handles GitHub API rate limit errors
  """
  defp handle_rate_limit_error(headers, resp) do
    case get_in(headers, ["x-ratelimit-remaining"]) do
      "0" ->
        reset_time =
          get_in(headers, ["x-ratelimit-reset"])
          |> String.to_integer()
          |> DateTime.from_unix!()
          |> DateTime.to_string()

        raise "GitHub API rate limit exceeded. Resets at #{reset_time}"

      _ ->
        raise "GitHub API access denied. Response: #{inspect(resp)}"
    end
  end

  @doc """
  Filters releases to only include those after the cutoff date
  """
  defp filter_recent_releases(releases) do
    {:ok, cutoff_date, _} = DateTime.from_iso8601(@cutoff_date)

    Enum.filter(releases, fn release ->
      {:ok, published_at, _} = DateTime.from_iso8601(release["published_at"])
      DateTime.compare(published_at, cutoff_date) == :gt
    end)
  end

  @doc """
  Generates and writes version data files
  """
  defp write_version_data(releases) do
    versions_data = %{
      "versions" =>
        Enum.map(releases, fn release ->
          has_elixir_assets =
            Enum.any?(release["assets"], &Regex.match?(@esp32_elixir_regex, &1["name"]))

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

    # Write JSON version
    versions_json_path = Path.join(@config.assets_dir, "versions.json")
    IO.puts("Writing versions data to #{versions_json_path}")
    File.write!(versions_json_path, Jason.encode!(versions_data, pretty: true))

    # Write YAML version
    versions_yml_path = Path.join("_data", "versions.yml")
    IO.puts("Writing versions data to #{versions_yml_path}")
    File.write!(versions_yml_path, Ymlr.document!(versions_data))
  end

  @doc """
  Determines supported boards based on asset names
  """
  defp get_supported_boards(assets) do
    Enum.reduce(assets, MapSet.new(), fn asset, acc ->
      find_and_add_board(asset["name"], acc)
    end)
  end

  @doc """
  Identifies board type from asset name and adds it to the accumulator
  """
  defp find_and_add_board(name, acc) do
    Enum.reduce(@chip_families, acc, fn {regex, board_name}, board_acc ->
      if String.match?(name, regex), do: MapSet.put(board_acc, board_name), else: board_acc
    end)
  end

  @doc """
  Processes Pico-related release assets
  """
  defp process_pico_release(release) do
    pico_assets =
      Enum.filter(release["assets"], &Regex.match?(@pico_firmware_regex, &1["name"]))

    pico_atomvmlib_assets =
      Enum.filter(release["assets"], &Regex.match?(@pico_atomvmlib_regex, &1["name"]))

    IO.puts("#{release["tag_name"]}: Found #{length(pico_assets)} Pico matching firmware assets")

    tag_dir = ensure_tag_directory(release["tag_name"])

    atomvmlib_path = download_atomvmlib_if_available(pico_atomvmlib_assets, tag_dir)
    create_combined_pico_assets(pico_assets, atomvmlib_path, tag_dir)
  end

  @doc """
  Downloads atomvmlib assets if available and returns the path
  """
  defp download_atomvmlib_if_available([], _tag_dir), do: false

  defp download_atomvmlib_if_available([asset | _], tag_dir) do
    asset_path = Path.join(tag_dir, asset["name"])
    download_asset(asset, asset_path)
    asset_path
  end

  @doc """
  Creates combined Pico assets by merging firmware with atomvmlib
  """
  defp create_combined_pico_assets(_pico_assets, false, _tag_dir), do: :ok
  defp create_combined_pico_assets([], _atomvmlib_path, _tag_dir), do: :ok

  defp create_combined_pico_assets(pico_assets, atomvmlib_path, tag_dir) do
    Enum.each(pico_assets, fn asset ->
      asset_path = Path.join(tag_dir, asset["name"])
      download_asset(asset, asset_path)

      combined_asset_path = Path.join(tag_dir, "combined_#{asset["name"]}")
      :uf2tool.uf2join(combined_asset_path, [asset_path, atomvmlib_path])
      IO.puts("Created combined UF2 at #{combined_asset_path}")
    end)
  end

  @doc """
  Processes ESP32-related release assets
  """
  defp process_esp32_release(release) do
    esp32_assets =
      Enum.filter(release["assets"], &Regex.match?(@esp32_firmware_regex, &1["name"]))

    IO.puts(
      "#{release["tag_name"]}: Found #{length(esp32_assets)} ESP32 matching firmware assets"
    )

    if Enum.empty?(esp32_assets) do
      :ok
    else
      tag_dir = ensure_tag_directory(release["tag_name"])

      # Split assets into standard and Elixir variants
      {standard_assets, elixir_assets} =
        Enum.split_with(esp32_assets, &(!String.contains?(&1["name"], "-elixir-")))

      # Process standard release data
      write_esp32_release_data(release, standard_assets, tag_dir, "esp32_release.json")

      # Process Elixir release data if available
      unless Enum.empty?(elixir_assets) do
        write_esp32_release_data(release, elixir_assets, tag_dir, "esp32_release-elixir.json")
      end

      # Download all assets
      Enum.each(esp32_assets, fn asset ->
        asset_path = Path.join(tag_dir, asset["name"])
        download_asset(asset, asset_path)
      end)
    end
  end

  @doc """
  Ensures tag directory exists and returns the path
  """
  defp ensure_tag_directory(tag_name) do
    tag_dir = Path.join(@config.assets_dir, tag_name)
    File.mkdir_p!(tag_dir)
    tag_dir
  end

  @doc """
  Creates and writes ESP32 release data
  """
  defp write_esp32_release_data(release, assets, tag_dir, filename) do
    release_data = create_release_data(release, assets)
    json_path = Path.join(tag_dir, filename)
    IO.puts("Writing release data to #{json_path}")
    File.write!(json_path, Jason.encode!(release_data, pretty: true))
  end

  @doc """
  Creates release data structure for ESP32 firmware
  """
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
                "path" => asset["name"],
                "offset" => get_offset(asset["name"])
              }
            ]
          }
        end)
    }
  end

  @doc """
  Downloads an asset if it doesn't exist or has wrong size
  """
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

  @doc """
  Performs the actual asset download
  """
  defp do_download_asset(asset, asset_path) do
    IO.puts(
      "Downloading asset: #{asset["name"]} (#{Float.round(asset["size"] / 1024 / 1024, 2)} MB)"
    )

    headers = [
      {"Accept", "application/octet-stream"},
      {"User-Agent", "AtomVM-Releases-Fetcher"}
    ]

    case Req.get!(asset["browser_download_url"], headers: headers) do
      %{status: 200, body: body} ->
        File.write!(asset_path, body)
        IO.puts("Successfully saved asset to #{asset_path}")

      resp ->
        File.rm(asset_path)
        raise "Failed to download asset #{asset["name"]}: #{inspect(resp)}"
    end
  end

  @doc """
  Determines the chip family from an asset name
  """
  def get_chip_family(name) do
    Enum.find_value(@chip_families, "UNKNOWN", fn {regex, family} ->
      if String.match?(name, regex), do: family, else: nil
    end)
  end

  @doc """
  Determines the flash offset for a particular chip
  """
  def get_offset(name) do
    cond do
      String.match?(name, ~r/esp32p4/i) -> 8192
      String.match?(name, ~r/esp32-/i) -> 4096
      String.match?(name, ~r/esp32s2/i) -> 4096
      true -> 0
    end
  end
end

AtomVMReleasesFetcher.main()
