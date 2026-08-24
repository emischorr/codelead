defmodule CodeLeadWeb.ForgeLinks do
  @moduledoc """
  Browser-facing file URLs for paths cited by findings.

  Builds a link only for forges `CodeLead.Git.forge/1` recognizes
  (github.com and gitlab.com); anything else — including self-hosted
  forges, which `forge/1` cannot identify — yields `nil` and the path
  renders as plain text.
  """

  alias CodeLead.Git

  @doc """
  URL to a cited file on the default branch, with a line anchor when
  the path carries a `:line` suffix (`"lib/foo.ex:42"`).
  """
  @spec file_url(Git.forge(), String.t(), String.t()) :: String.t() | nil
  def file_url(forge, default_branch, cited_path) do
    {path, line} = split_line(cited_path)
    blob_url(forge, default_branch, path, line)
  end

  defp blob_url({:github, owner, repo}, branch, path, line) do
    "https://github.com/#{owner}/#{repo}/blob/#{branch}/#{path}#{anchor(line)}"
  end

  defp blob_url({:gitlab, owner, repo}, branch, path, line) do
    "https://gitlab.com/#{owner}/#{repo}/-/blob/#{branch}/#{path}#{anchor(line)}"
  end

  defp blob_url(:other, _branch, _path, _line), do: nil

  defp split_line(cited_path) do
    case Regex.run(~r/^(.+):(\d+)$/, cited_path) do
      [_match, path, line] -> {path, line}
      nil -> {cited_path, nil}
    end
  end

  defp anchor(nil), do: ""
  defp anchor(line), do: "#L#{line}"
end
