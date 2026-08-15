defmodule CodeLeadWeb.FormOptions do
  @moduledoc """
  Select options and label copy for the enums the setup wizard and the
  settings pages both edit. Kept in one place so the two surfaces cannot
  drift apart — the wizard creates a provider or an agent, settings edits
  the same row later.

  Roles are a special case: `agents.roles` is an array, but the form offers
  the three combinations that make sense as a single select, so
  `parse_roles/1` and `role_value/1` convert between the two.
  """

  @spec provider_kinds() :: [{String.t(), String.t()}]
  def provider_kinds do
    [
      {"Anthropic — API key", "anthropic_api"},
      {"Anthropic — subscription (OAuth token)", "anthropic_subscription"},
      {"OpenAI", "openai"},
      {"Ollama (local)", "ollama"}
    ]
  end

  @spec credential_type(String.t() | atom() | nil) :: String.t()
  def credential_type(kind) when kind in ["ollama", :ollama], do: "url"
  def credential_type(_kind), do: "password"

  @spec credential_label(String.t() | atom() | nil) :: String.t()
  def credential_label(kind) when kind in ["ollama", :ollama], do: "Endpoint URL"

  def credential_label(kind) when kind in ["anthropic_subscription", :anthropic_subscription],
    do: "OAuth token"

  def credential_label(_kind), do: "API key"

  @spec credential_placeholder(String.t() | atom() | nil) :: String.t() | nil
  def credential_placeholder(kind) when kind in ["ollama", :ollama], do: "http://localhost:11434"
  def credential_placeholder(_kind), do: nil

  @doc """
  Whether a kind's credential is a secret. An Ollama endpoint is a plain URL
  and is safe to show; everything else must be masked.
  """
  @spec secret_credential?(String.t() | atom() | nil) :: boolean()
  def secret_credential?(kind), do: kind not in ["ollama", :ollama]

  @spec provider_kind_label(String.t() | atom() | nil) :: String.t()
  def provider_kind_label(kind) do
    kind = to_string(kind)

    Enum.find_value(provider_kinds(), kind, fn {label, value} -> value == kind && label end)
  end

  @spec work_types() :: [{String.t(), String.t()}]
  def work_types do
    [{"Code", "code"}, {"Design", "design"}, {"Content", "content"}, {"File", "file"}]
  end

  @spec work_type_values() :: [atom()]
  def work_type_values, do: [:code, :design, :content, :file]

  @spec targets() :: [{String.t(), String.t()}]
  def targets, do: [{"Repository", "repo"}, {"Folder", "folder"}]

  @doc """
  The 10 selectable project identity colors, in the order the swatch
  picker offers them. Orange is left out — it is `--warn`'s color, used
  for the attention pill and banner, so a project could otherwise look
  like it needs attention when it doesn't.
  """
  @spec project_colors() :: [{String.t(), String.t()}]
  def project_colors do
    [
      {"Blue", "blue"},
      {"Indigo", "indigo"},
      {"Violet", "violet"},
      {"Pink", "pink"},
      {"Red", "red"},
      {"Cyan", "cyan"},
      {"Teal", "teal"},
      {"Green", "green"},
      {"Lime", "lime"},
      {"Yellow", "yellow"}
    ]
  end

  @doc """
  Finalize modes a target can use, labelled with what each one does.
  """
  @spec finalize_modes(:repo | :folder) :: [{String.t(), String.t()}]
  def finalize_modes(:repo) do
    [
      {"Pull request — push the branch, open a PR/MR", "pull_request"},
      {"Merge — merge into the default branch", "merge"},
      {"Squash — land it as a single commit", "squash"}
    ]
  end

  def finalize_modes(:folder) do
    [
      {"Artifact — hand the task folder over as a download", "artifact"},
      {"Commit to path — push the folder into a repository", "commit_to_path"}
    ]
  end

  @doc """
  The short label for a finalize mode — for naming the inherited project
  default in a select.
  """
  @spec finalize_mode_label(atom()) :: String.t()
  def finalize_mode_label(:pull_request), do: "Pull request"
  def finalize_mode_label(:merge), do: "Merge"
  def finalize_mode_label(:squash), do: "Squash"
  def finalize_mode_label(:artifact), do: "Artifact"
  def finalize_mode_label(:commit_to_path), do: "Commit to path"

  @spec roles() :: [{String.t(), String.t()}]
  def roles do
    [
      {"Execute and review", "execute,review"},
      {"Execute only", "execute"},
      {"Review only", "review"}
    ]
  end

  @doc """
  Turns the roles select value into the atom list the schema stores.
  """
  @spec parse_roles(String.t() | nil) :: [atom()]
  def parse_roles("execute"), do: [:execute]
  def parse_roles("review"), do: [:review]
  def parse_roles(_both), do: [:execute, :review]

  @doc """
  The inverse of `parse_roles/1`, for pre-selecting the roles select.
  """
  @spec role_value([atom() | String.t()] | nil) :: String.t()
  def role_value(roles) when is_list(roles) do
    case Enum.map(roles, &to_string/1) do
      ["execute"] -> "execute"
      ["review"] -> "review"
      _both -> "execute,review"
    end
  end

  def role_value(_roles), do: "execute,review"

  @spec drivers() :: [{String.t(), String.t()}]
  def drivers do
    [{"ACP — a full coding harness", "acp"}, {"LLM API — a single model call", "llm_api"}]
  end

  @spec harnesses() :: [{String.t(), String.t()}]
  def harnesses, do: [{"Claude Code", "claude_code"}, {"Codex", "codex"}]

  @spec execution_envs() :: [{String.t(), String.t()}]
  def execution_envs, do: [{"Local", "local"}, {"Container", "container"}]

  @spec locales() :: [{String.t(), String.t()}]
  def locales, do: [{"English", "en"}]

  @spec locale_values() :: [String.t()]
  def locale_values, do: Enum.map(locales(), fn {_label, value} -> value end)

  @doc """
  Timezone options for the profile page. The first entry (`""`) means
  "follow the browser" — actual conversion happens client-side via `Intl`,
  which accepts any IANA zone name natively, so this list is just the
  curated set offered in the select, not a completeness claim.
  """
  @spec timezones() :: [{String.t(), String.t()}]
  def timezones do
    [
      {"Automatic (browser default)", ""},
      {"UTC", "Etc/UTC"},
      {"London", "Europe/London"},
      {"Dublin", "Europe/Dublin"},
      {"Lisbon", "Europe/Lisbon"},
      {"Berlin, Paris, Madrid, Rome", "Europe/Berlin"},
      {"Amsterdam, Brussels", "Europe/Amsterdam"},
      {"Warsaw, Prague, Budapest", "Europe/Warsaw"},
      {"Athens, Helsinki, Bucharest", "Europe/Athens"},
      {"Moscow", "Europe/Moscow"},
      {"Istanbul", "Europe/Istanbul"},
      {"Cairo", "Africa/Cairo"},
      {"Johannesburg", "Africa/Johannesburg"},
      {"Lagos", "Africa/Lagos"},
      {"Nairobi", "Africa/Nairobi"},
      {"Dubai", "Asia/Dubai"},
      {"Tehran", "Asia/Tehran"},
      {"Karachi", "Asia/Karachi"},
      {"Mumbai, New Delhi", "Asia/Kolkata"},
      {"Dhaka", "Asia/Dhaka"},
      {"Bangkok, Jakarta", "Asia/Bangkok"},
      {"Singapore, Kuala Lumpur", "Asia/Singapore"},
      {"Hong Kong", "Asia/Hong_Kong"},
      {"Shanghai, Beijing", "Asia/Shanghai"},
      {"Taipei", "Asia/Taipei"},
      {"Tokyo, Seoul", "Asia/Tokyo"},
      {"Manila", "Asia/Manila"},
      {"Perth", "Australia/Perth"},
      {"Adelaide", "Australia/Adelaide"},
      {"Sydney, Melbourne, Brisbane", "Australia/Sydney"},
      {"Auckland", "Pacific/Auckland"},
      {"Honolulu", "Pacific/Honolulu"},
      {"Anchorage", "America/Anchorage"},
      {"Los Angeles, Vancouver (Pacific)", "America/Los_Angeles"},
      {"Denver, Phoenix (Mountain)", "America/Denver"},
      {"Chicago, Mexico City (Central)", "America/Chicago"},
      {"New York, Toronto (Eastern)", "America/New_York"},
      {"Halifax", "America/Halifax"},
      {"São Paulo", "America/Sao_Paulo"},
      {"Buenos Aires", "America/Argentina/Buenos_Aires"},
      {"Santiago", "America/Santiago"},
      {"Bogotá, Lima", "America/Bogota"}
    ]
  end

  @spec timezone_values() :: [String.t()]
  def timezone_values, do: Enum.map(timezones(), fn {_label, value} -> value end)

  @spec provider_options([%{name: String.t(), id: pos_integer()}]) :: [
          {String.t(), pos_integer()}
        ]
  def provider_options(providers), do: Enum.map(providers, &{&1.name, &1.id})

  @doc """
  The agent form's project select: "All projects" (org scope, blank
  value) followed by every project (project scope, bound to its id).
  """
  @spec project_options([%{name: String.t(), id: pos_integer()}]) :: [
          {String.t(), String.t() | pos_integer()}
        ]
  def project_options(projects) do
    [{"All projects", ""} | Enum.map(projects, &{&1.name, &1.id})]
  end
end
