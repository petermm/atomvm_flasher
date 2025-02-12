#!/usr/bin/env elixir

Mix.install([
  {:req, "~> 0.4.0"},
  {:jason, "~> 1.4"},
  {:ymlr, "~> 3.0"}
])

Code.require_file("scripts/fetch-releases.exs")

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
         {:ok, latest_run} <-
           get_latest_workflow_run(req_client, owner, repo, repo_branch, workflow_id) do
      case get_run_artifacts(req_client, owner, repo, latest_run["id"]) do
        {:ok, artifacts} ->
          IO.inspect(latest_run)
          IO.inspect(artifacts)
          {:ok, artifacts, latest_run}

        error ->
          error
      end
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

  defp get_latest_workflow_run(req_client, owner, repo, repo_branch, workflow_id) do
    case Req.get(req_client,
           url: "/repos/#{owner}/#{repo}/actions/workflows/#{workflow_id}/runs",
           params: [branch: repo_branch, per_page: 1]
         ) do
      {:ok, %{status: 200, body: %{"workflow_runs" => []}}} ->
        {:error, "No workflow runs found"}

      {:ok, %{status: 200, body: %{"workflow_runs" => [latest_run | _]}}} ->
        {:ok, latest_run}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, _} = error ->
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

  def create_release_data(release, assets, elixir \\ true) do
    assets =
      if elixir do
        assets |> Enum.filter(fn asset -> String.contains?(asset["name"], "elixir") end)
      else
        assets |> Enum.filter(fn asset -> !String.contains?(asset["name"], "elixir") end)
      end

    %{
      "name" => "AtomVM-#{release["name"]}",
      "version" => release["head_sha"],
      "published_at" => release["updated_at"],
      # "html_url" => release["head_repository"],
      "new_install_improv_wait_time" => 0,
      "builds" =>
        Enum.map(assets, fn asset ->
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
end

# Get token from environment
token = System.get_env("GITHUB_TOKEN")

unless token do
  IO.puts("Error: GITHUB_TOKEN environment variable is not set")
  System.halt(1)
end

# Check if unzip is available
case System.cmd("which", ["unzip"]) do
  {_, 0} ->
    :ok

  _ ->
    IO.puts("Error: 'unzip' command not found. Please install unzip.")
    System.halt(1)
end

# Get command line arguments or use defaults
{owner, repo, repo_branch, workflow_name} =
  case System.argv() do
    [o, r, b, w] ->
      {o, r, b, w}

    _ ->
      IO.puts("Usage: ./script.exs owner repo workflow_name")
      System.halt(1)
  end

branches = String.split(repo_branch, ",")
branches_dir = Path.join(["assets", "branch"])

# Clean up old branch directories
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

Enum.each(branches, fn branch_name ->
  case GitHubArtifacts.get_workflow_artifacts(owner, repo, branch_name, workflow_name, token) do
    {:ok, artifacts, branch} ->
      if Enum.empty?(artifacts) do
        IO.puts("No artifacts found")
      else
        output_dir = Path.join(["assets", "branch", branch["head_branch"]])
        File.mkdir_p!(output_dir)
        last_download_file = Path.join(output_dir, "last_download")

        release_data = GitHubArtifacts.create_release_data(branch, artifacts, false)
        json_file = Path.join(output_dir, "latest_#{branch["head_branch"]}.json")
        File.write!(json_file, Jason.encode!(release_data, pretty: true))

        release_data_elixir = GitHubArtifacts.create_release_data(branch, artifacts)
        json_file_elixir = Path.join(output_dir, "latest_#{branch["head_branch"]}-elixir.json")
        File.write!(json_file_elixir, Jason.encode!(release_data_elixir, pretty: true))

        # Check if this is a new run by comparing with last_download file
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
      end

    {:error, reason} ->
      IO.puts("Error: #{inspect(reason)}")
      System.halt(1)
  end
end)
