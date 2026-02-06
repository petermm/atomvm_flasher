#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.4.0"},
  {:jason, "~> 1.4"},
  {:ymlr, "~> 3.0"},
  {:uf2tool, "1.1.0"}
])

Code.require_file(Path.expand("atomvm_releases_fetcher.exs", __DIR__))

defmodule GitHubArtifacts do
  @base_url "https://api.github.com"

  def get_workflow_artifacts(owner, repo, repo_branch, workflow_name, token) do
    req_client =
      Req.new(
        base_url: @base_url,
        auth: {:bearer, token},
        headers: [
          accept: "application/vnd.github+json",
          "x-github-api-version": "2022-11-28"
        ]
      )

    with {:ok, workflow_id} <- get_workflow_id(req_client, owner, repo, workflow_name),
         {:ok, recent_runs} <-
           get_recent_workflow_runs(req_client, owner, repo, repo_branch, workflow_id) do
      find_run_with_artifacts(req_client, owner, repo, recent_runs)
    end
  end

  def download_and_extract_artifact(artifact, token, output_dir) do
    # Create download client with token but different headers for artifact download
    req_client =
      Req.new(
        auth: {:bearer, token},
        headers: [
          accept: "application/vnd.github+json"
        ]
      )

    # Ensure output directory exists
    File.mkdir_p!(output_dir)

    # Create a temporary directory for the zip file
    temp_dir = Path.join(System.tmp_dir!(), "github_artifacts_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(temp_dir)
    zip_path = Path.join(temp_dir, "#{artifact["name"]}.zip")

    try do
      # Download the artifact
      case Req.get(req_client,
             url: artifact["archive_download_url"],
             into: File.stream!(zip_path, [:write])
           ) do
        {:ok, _response} ->
          IO.puts("Downloaded #{artifact["name"]} to #{zip_path}")

          # Unzip the file
          case System.cmd("unzip", ["-o", "-q", zip_path, "-d", output_dir]) do
            {_, 0} ->
              IO.puts("Extracted to #{output_dir}")
              {:ok, output_dir}

            {error, _} ->
              {:error, "Extraction failed: #{error}"}
          end

        {:error, reason} ->
          IO.puts("Error downloading #{artifact["name"]}: #{inspect(reason)}")
          {:error, reason}
      end
    after
      # Clean up temporary files
      File.rm_rf!(temp_dir)
    end
  end

  defp get_workflow_id(req_client, owner, repo, workflow_name) do
    case Req.get(req_client, url: "/repos/#{owner}/#{repo}/actions/workflows") do
      {:ok, %{status: 200, body: %{"workflows" => workflows}}} ->
        workflow = Enum.find(workflows, fn w -> w["name"] == workflow_name end)

        case workflow do
          nil -> {:error, "Workflow '#{workflow_name}' not found"}
          workflow -> {:ok, workflow["id"]}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, _} = error ->
        error
    end
  end

  defp get_recent_workflow_runs(req_client, owner, repo, repo_branch, workflow_id) do
    case Req.get(req_client,
           url: "/repos/#{owner}/#{repo}/actions/workflows/#{workflow_id}/runs",
           params: [branch: repo_branch, status: "success", per_page: 10]
         ) do
      {:ok, %{status: 200, body: %{"workflow_runs" => []}}} ->
        {:error, "No successful workflow runs found"}

      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}} ->
        {:ok, runs}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, _} = error ->
        error
    end
  end

  defp find_run_with_artifacts(_req_client, _owner, _repo, []) do
    {:error, "No workflow runs with artifacts found in recent history"}
  end

  defp find_run_with_artifacts(req_client, owner, repo, [run | rest]) do
    IO.puts("Checking run ##{run["run_number"]} (#{run["head_sha"] |> String.slice(0, 7)}) for artifacts...")

    case get_run_artifacts(req_client, owner, repo, run["id"]) do
      {:ok, []} ->
        IO.puts("  No artifacts, trying previous run...")
        find_run_with_artifacts(req_client, owner, repo, rest)

      {:ok, artifacts} ->
        IO.puts("  Found #{length(artifacts)} artifacts")
        {:ok, artifacts, run}

      error ->
        error
    end
  end

  defp get_run_artifacts(req_client, owner, repo, run_id) do
    case Req.get(req_client, url: "/repos/#{owner}/#{repo}/actions/runs/#{run_id}/artifacts") do
      {:ok, %{status: 200, body: %{"artifacts" => artifacts}}} ->
        {:ok, artifacts}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, _} = error ->
        error
    end
  end

  def create_release_data(release, assets, opts \\ []) do
    elixir = Keyword.get(opts, :elixir, true)
    name = Keyword.get(opts, :name, "AtomVM-esp32-mkimage")

    assets =
      if elixir do
        assets |> Enum.filter(fn asset -> String.contains?(asset["name"], "elixir") end)
      else
        assets |> Enum.filter(fn asset -> !String.contains?(asset["name"], "elixir") end)
      end

    %{
      "name" => name,
      "version" => release["head_sha"],
      "published_at" => release["updated_at"],
      # "html_url" => release["head_repository"],
      "new_install_prompt_erase" => true,
      "new_install_improv_wait_time" => 0,
      "builds" =>
        assets
        |> Enum.sort_by(fn x -> x["name"] end)
        |> Enum.map(fn asset ->
          %{
            "chipFamily" => AtomVMReleasesFetcher.get_chip_family(asset["name"]),
            "parts" => [
              %{
                "path" => "#{asset["name"]}.img" |> String.replace("-image", ""),
                "offset" => AtomVMReleasesFetcher.get_offset(asset["name"])
              }
            ]
          }
        end)
    }
  end

  def write_branch_manifests(branch, artifacts, output_dir) do
    branch_name = branch["head_branch"]
    base_filename = "latest_#{branch_name}"

    {regular_artifacts, p4_variant_artifacts} =
      Enum.split_with(artifacts, fn artifact -> p4_variant_key(artifact["name"]) == nil end)

    release_data =
      create_release_data(branch, regular_artifacts, elixir: false, name: "AtomVM-esp32-mkimage")

    json_file = Path.join(output_dir, "#{base_filename}.json")
    File.write!(json_file, Jason.encode!(release_data, pretty: true))

    release_data_elixir =
      create_release_data(branch, regular_artifacts, elixir: true, name: "AtomVM-esp32-mkimage")

    json_file_elixir = Path.join(output_dir, "#{base_filename}-elixir.json")
    File.write!(json_file_elixir, Jason.encode!(release_data_elixir, pretty: true))

    p4_variants = write_p4_variant_manifests(branch, p4_variant_artifacts, output_dir, base_filename)

    %{release_data: release_data, p4_variants: p4_variants}
  end

  defp write_p4_variant_manifests(branch, artifacts, output_dir, base_filename) do
    p4_variants()
    |> Enum.reduce([], fn %{key: key, suffix: suffix, label: label, name: name_fun}, acc ->
      variant_assets =
        Enum.filter(artifacts, fn artifact -> p4_variant_key(artifact["name"]) == key end)

      has_erlang =
        write_optional_variant_manifest(
          branch,
          variant_assets,
          output_dir,
          "#{base_filename}-#{suffix}.json",
          false,
          name_fun.(false)
        )

      has_elixir =
        write_optional_variant_manifest(
          branch,
          variant_assets,
          output_dir,
          "#{base_filename}-#{suffix}-elixir.json",
          true,
          name_fun.(true)
        )

      if has_erlang or has_elixir do
        [
          %{
            "suffix" => suffix,
            "label" => label,
            "has_erlang" => has_erlang,
            "has_elixir" => has_elixir
          }
          | acc
        ]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp write_optional_variant_manifest(branch, artifacts, output_dir, filename, elixir?, name) do
    filtered =
      if elixir? do
        Enum.filter(artifacts, fn a -> String.contains?(a["name"], "elixir") end)
      else
        Enum.reject(artifacts, fn a -> String.contains?(a["name"], "elixir") end)
      end

    manifest_path = Path.join(output_dir, filename)

    case filtered do
      [] ->
        if File.exists?(manifest_path), do: File.rm!(manifest_path)
        false

      assets ->
        data = create_release_data(branch, assets, elixir: elixir?, name: name)
        File.write!(manifest_path, Jason.encode!(data, pretty: true))
        true
    end
  end

  defp p4_variants do
    [
      %{
        key: :p4_c6,
        suffix: "p4_c6",
        label: "P4 + C6",
        name: fn elixir? -> "AtomVM-esp32p4_c6" <> if(elixir?, do: "-elixir", else: "") end
      },
      %{
        key: :p4_pre,
        suffix: "p4_pre",
        label: "P4 Pre",
        name: fn elixir? ->
          if elixir?, do: "AtomVM-esp32p4_pre-elixir", else: "AtomVM-esp32p4_pre-mkimage"
        end
      },
      %{
        key: :p4_pre_c6,
        suffix: "p4_pre_c6",
        label: "P4 Pre + C6",
        name: fn elixir? -> "AtomVM-esp32p4_pre_c6" <> if(elixir?, do: "-elixir", else: "") end
      }
    ]
  end

  defp p4_variant_key(name) do
    cond do
      String.match?(name, ~r/esp32p4_pre_c6/i) -> :p4_pre_c6
      String.match?(name, ~r/esp32p4_pre/i) -> :p4_pre
      String.match?(name, ~r/esp32p4_c6/i) -> :p4_c6
      true -> nil
    end
  end
end

defmodule FetchArtifactsCLI do
  def main do
    token = System.get_env("GITHUB_TOKEN")

    unless token do
      IO.puts("Error: GITHUB_TOKEN environment variable is not set")
      System.halt(1)
    end

    case System.cmd("which", ["unzip"]) do
      {_, 0} ->
        :ok

      _ ->
        IO.puts("Error: 'unzip' command not found. Please install unzip.")
        System.halt(1)
    end

    {owner, repo, repo_branch, workflow_name} =
      case System.argv() do
        [o, r, b, w] ->
          {o, r, b, w}

        _ ->
          IO.puts("Usage: ./fetch-artifacts.exs owner repo branches_csv workflow_name")
          System.halt(1)
      end

    branches = String.split(repo_branch, ",")
    branches_dir = Path.join(["assets", "branch_ci_binaries"])
    File.mkdir_p!(branches_dir)

    branch_metadata = %{}

    if File.exists?(branches_dir) do
      File.ls!(branches_dir)
      |> Enum.filter(&File.dir?(Path.join(branches_dir, &1)))
      |> Enum.each(fn dir ->
        if dir not in branches do
          IO.puts("Removing old branch directory: #{dir}")
          File.rm_rf!(Path.join(branches_dir, dir))
        end
      end)
    end

    branch_metadata =
      Enum.reduce(branches, branch_metadata, fn branch_name, acc ->
        case GitHubArtifacts.get_workflow_artifacts(owner, repo, branch_name, workflow_name, token) do
          {:ok, artifacts, branch} ->
            if Enum.empty?(artifacts) do
              IO.puts("No artifacts found")
              acc
            else
              output_dir = Path.join([branches_dir, branch["head_branch"]])
              File.mkdir_p!(output_dir)
              last_download_file = Path.join(output_dir, "last_download")

              release_data = GitHubArtifacts.write_branch_manifests(branch, artifacts, output_dir)

              is_new_run =
                case File.read(last_download_file) do
                  {:ok, last_branch} -> String.trim(last_branch) != branch["head_sha"]
                  {:error, _} -> true
                end

              if is_new_run do
                IO.puts("\nProcessing #{length(artifacts)} artifacts to #{output_dir}")
                File.mkdir_p!(output_dir)
                File.write!(last_download_file, branch["head_sha"])

                Enum.each(artifacts, fn artifact ->
                  IO.puts("\nArtifact: #{artifact["name"]}")
                  IO.puts("Size: #{artifact["size_in_bytes"]} bytes")

                  case GitHubArtifacts.download_and_extract_artifact(artifact, token, output_dir) do
                    {:ok, path} -> IO.puts("Successfully extracted to: #{path}")
                    {:error, reason} -> IO.puts("Failed: #{inspect(reason)}")
                  end
                end)
              else
                IO.puts("Skipping download: branch #{branch["head_branch"]} already processed")
              end

              supported_boards =
                release_data.release_data["builds"]
                |> Enum.map(fn build -> build["chipFamily"] end)
                |> Enum.uniq()
                |> Enum.sort()

              Map.put(acc, branch["head_branch"], %{
                "sha" => branch["head_sha"],
                "published_at" => branch["updated_at"],
                "supported_boards" => supported_boards,
                "p4_variants" => release_data.p4_variants
              })
            end

          {:error, reason} ->
            IO.puts("Error: #{inspect(reason)}")
            System.halt(1)
        end
      end)

    branches_yml_path = Path.join("_data", "branches.yml")
    IO.puts("Writing branch metadata to #{branches_yml_path}")
    File.write!(branches_yml_path, Ymlr.document!(branch_metadata))
  end
end

if System.get_env("FETCH_ARTIFACTS_SKIP_MAIN") != "1" do
  FetchArtifactsCLI.main()
end
