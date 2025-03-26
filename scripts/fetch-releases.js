#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const yaml = require("js-yaml");
const { Octokit } = require("@octokit/rest");

// Configuration
const config = {
  owner: "atomvm",
  repo: "atomvm",
  assetsDir: "assets",
  token: process.env.GITHUB_TOKEN || process.env.GH_TOKEN,
};

const octokit = new Octokit({
  auth: config.token,
  userAgent: "AtomVM-Releases-Fetcher",
});

// Ensure assets directory exists
function ensureAssetsDir() {
  if (!fs.existsSync(config.assetsDir)) {
    console.log(`Creating assets directory: ${config.assetsDir}`);
    fs.mkdirSync(config.assetsDir, { recursive: true });
  }
}

// Fetch releases from GitHub API
async function fetchReleases() {
  console.log("Fetching releases from atomvm/atomvm repository...");
  try {
    const { data: releases } = await octokit.rest.repos.listReleases({
      owner: config.owner,
      repo: config.repo,
      per_page: 100,
    });
    return releases;
  } catch (error) {
    if (
      error.status === 403 &&
      error.response.headers["x-ratelimit-remaining"] === "0"
    ) {
      const resetTime = new Date(
        error.response.headers["x-ratelimit-reset"] * 1000
      );
      throw new Error(
        `GitHub API rate limit exceeded. Resets at ${resetTime.toLocaleString()}`
      );
    }
    throw error;
  }
}

// Download asset file
async function downloadAsset(url, filePath) {
  try {
    const fetch = require("node-fetch");
    const response = await fetch(url, {
      headers: {
        Authorization: `token ${config.token}`,
        Accept: "application/octet-stream",
        "User-Agent": "AtomVM-Releases-Fetcher",
      },
    });

    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`);
    }

    const buffer = await response.buffer();
    fs.writeFileSync(filePath, buffer);
  } catch (error) {
    fs.unlink(filePath, () => {});
    if (error.response?.status === 403) {
      if (error.response?.headers?.["x-ratelimit-remaining"] === "0") {
        const resetTime = new Date(
          parseInt(error.response.headers["x-ratelimit-reset"]) * 1000
        );
        throw new Error(
          `GitHub API rate limit exceeded. Resets at ${resetTime.toLocaleString()}`
        );
      } else {
        throw new Error(
          "GitHub API access denied. Please ensure you have a valid GITHUB_TOKEN environment variable set."
        );
      }
    }
    throw new Error(`Failed to download asset: ${error.message}`);
  }
}

// Main function
async function main() {
  try {
    ensureAssetsDir();

    const releases = await fetchReleases();
    console.log(`Found ${releases.length} releases`);

    // Filter releases by date before creating versions.json
    const cutoffDate = new Date("2021-03-05T17:33:14Z");
    const recentReleases = releases.filter(
      (release) => new Date(release.published_at) > cutoffDate
    );

    // Create versions.json data with filtered releases
    const versionsData = {
      versions: recentReleases.map((release) => {
        const hasElixirAssets = release.assets.some((asset) =>
          /^AtomVM-esp32(?:[cp][2-6]|s[23])?-elixir-v\d+\.\d+\.\d+\.img$/.test(
            asset.name
          )
        );

        // Generate supported boards based on available assets
        const supportedBoards = new Set();
        release.assets.forEach((asset) => {
          if (asset.name.match(/^AtomVM-esp32p4-/))
            supportedBoards.add("ESP32-P4");
          else if (asset.name.match(/^AtomVM-esp32c5-/))
            supportedBoards.add("ESP32-C5");
          else if (asset.name.match(/^AtomVM-esp32c6-/))
            supportedBoards.add("ESP32-C6");
          else if (asset.name.match(/^AtomVM-esp32c3-/))
            supportedBoards.add("ESP32-C3");
          else if (asset.name.match(/^AtomVM-esp32c2-/))
            supportedBoards.add("ESP32-C2");
          else if (asset.name.match(/^AtomVM-esp32s3-/))
            supportedBoards.add("ESP32-S3");
          else if (asset.name.match(/^AtomVM-esp32s2-/))
            supportedBoards.add("ESP32-S2");
          else if (asset.name.match(/^AtomVM-esp32-/))
            supportedBoards.add("ESP32");
        });

        return {
          version: release.tag_name,
          published_at: release.published_at,
          html_url: release.html_url,
          has_elixir: hasElixirAssets,
          supported_boards: Array.from(supportedBoards).sort(),
        };
      }),
    };

    // Write versions.json
    const versionsJsonPath = path.join(config.assetsDir, "versions.json");
    console.log(`Writing versions data to ${versionsJsonPath}`);
    fs.writeFileSync(versionsJsonPath, JSON.stringify(versionsData, null, 2));

    // Write versions.yml
    const versionsYmlPath = path.join("_data", "versions.yml");
    console.log(`Writing versions data to ${versionsYmlPath}`);
    fs.writeFileSync(versionsYmlPath, yaml.dump(versionsData));

    for (const release of releases) {
      const assets = release.assets.filter((asset) =>
        /^AtomVM-esp32(?:[cp][2-6]|s[23])?(?:-elixir)?-v\d+\.\d+\.\d+\.img$/.test(
          asset.name
        )
      );

      console.log(`Processing release ${release.tag_name}`);
      console.log(`Found ${assets.length} matching firmware assets`);

      if (assets.length > 0) {
        // Create tag directory
        const tagDir = path.join(config.assetsDir, release.tag_name);
        const tagBinariesDir = path.join(tagDir, "binaries");
        if (!fs.existsSync(tagDir)) {
          fs.mkdirSync(tagDir, { recursive: true });
        }
        if (!fs.existsSync(tagBinariesDir)) {
          fs.mkdirSync(tagBinariesDir, { recursive: true });
        }

        // Split assets into standard and elixir
        const standardAssets = assets.filter(
          (asset) => !asset.name.includes("-elixir-")
        );
        const elixirAssets = assets.filter((asset) =>
          asset.name.includes("-elixir-")
        );

        // Create release data for standard firmware
        const standardReleaseData = {
          name: "AtomVM",
          version: release.tag_name,
          published_at: release.published_at,
          html_url: release.html_url,
          new_install_improv_wait_time: 0,
          builds: standardAssets.map((asset) => ({
            chipFamily: asset.name.match(/^AtomVM-esp32p4-/)
              ? "ESP32-P4"
              : asset.name.match(/^AtomVM-esp32c6-/)
              ? "ESP32-C6"
              : asset.name.match(/^AtomVM-esp32c3-/)
              ? "ESP32-C3"
              : asset.name.match(/^AtomVM-esp32c2-/)
              ? "ESP32-C2"
              : asset.name.match(/^AtomVM-esp32s3-/)
              ? "ESP32-S3"
              : asset.name.match(/^AtomVM-esp32s2-/)
              ? "ESP32-S2"
              : asset.name.match(/^AtomVM-esp32-/)
              ? "ESP32"
              : "UNKNOWN",
            parts: [
              {
                path: `binaries/${asset.name}`,
                offset: asset.name.match(/^AtomVM-esp32p4-/)
                  ? 8192
                  : asset.name.match(/^AtomVM-esp32(?:-|s2-)/)
                  ? 4096
                  : 0,
              },
            ],
          })),
        };

        // Create release data for elixir firmware
        const elixirReleaseData = {
          name: "AtomVM",
          version: release.tag_name,
          published_at: release.published_at,
          html_url: release.html_url,
          new_install_improv_wait_time: 0,
          builds: elixirAssets.map((asset) => ({
            chipFamily: asset.name.match(/^AtomVM-esp32p4-/)
              ? "ESP32-P4"
              : asset.name.match(/^AtomVM-esp32c6-/)
              ? "ESP32-C6"
              : asset.name.match(/^AtomVM-esp32c3-/)
              ? "ESP32-C3"
              : asset.name.match(/^AtomVM-esp32c2-/)
              ? "ESP32-C2"
              : asset.name.match(/^AtomVM-esp32s3-/)
              ? "ESP32-S3"
              : asset.name.match(/^AtomVM-esp32s2-/)
              ? "ESP32-S2"
              : asset.name.match(/^AtomVM-esp32-/)
              ? "ESP32"
              : "UNKNOWN",
            parts: [
              {
                path: `binaries/${asset.name}`,
                offset: asset.name.match(/^AtomVM-esp32p4-/)
                  ? 8192
                  : asset.name.match(/^AtomVM-esp32(?:-|s2-)/)
                  ? 4096
                  : 0,
              },
            ],
          })),
        };

        // Write standard release JSON
        const standardJsonPath = path.join(tagDir, "esp32_release.json");
        console.log(`Writing standard release data to ${standardJsonPath}`);
        fs.writeFileSync(
          standardJsonPath,
          JSON.stringify(standardReleaseData, null, 2)
        );

        // Write elixir release JSON if there are elixir assets
        if (elixirAssets.length > 0) {
          const elixirJsonPath = path.join(tagDir, "esp32_release-elixir.json");
          console.log(`Writing elixir release data to ${elixirJsonPath}`);
          fs.writeFileSync(
            elixirJsonPath,
            JSON.stringify(elixirReleaseData, null, 2)
          );
        }

        // Download assets
        for (const asset of assets) {
          const assetPath = path.join(tagBinariesDir, asset.name);

          // Check if file exists and has the correct size
          let shouldDownload = true;
          if (fs.existsSync(assetPath)) {
            const stats = fs.statSync(assetPath);
            if (stats.size === asset.size) {
              console.log(
                `Asset ${asset.name} already exists with correct size, skipping download`
              );
              shouldDownload = false;
            }
          }

          if (shouldDownload) {
            console.log(
              `Downloading asset: ${asset.name} (${(
                asset.size /
                1024 /
                1024
              ).toFixed(2)} MB)`
            );
            await downloadAsset(asset.browser_download_url, assetPath);
            console.log(`Successfully saved asset to ${assetPath}`);
          }
        }
      }
    }

    console.log("Release fetching completed successfully!");
  } catch (error) {
    console.error("Error:", error.message);
    process.exit(1);
  }
}

// Run the script
main();
