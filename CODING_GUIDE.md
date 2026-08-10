# Elixir Coding Guideline

## Ordering of functions and definitions inside a module

Every module should adhere to the following order:
1. Module doc (if existing)
2. `use`
3. `import` and `require`
4. `alias`
5. public functions `def`. If it's a GenServer start with the client facing functions like `start_link`
6. private functions `defp`

Functions of a kind (like `defp`) can be grouped by similarity or semantic.

## Function typespec definitions

Use the `@spec` keyword for typespec definitions for all public functions of a module to improve documentation.

## Use doctypes for public functions

Use the `@doc` keyword for public functions to improve documentation. Keep it short and concise. Mostly about the intent. Don't add information that can already be inferred from the @spec or the function header.

## Prefer atom keys in internally defined maps
Use atom keys for maps created in application code (e.g., option maps, config structs, function parameters). Maps deserialized from external sources (database JSON columns, API responses) use string keys — when validating these, look up both the atom and string key.

## Minimalize Parameters on public functions
Only require the necessary parameters and try to make it as reusable as possible.
For example instead of requiring a map structure just for one field:

    def main_repo_path(project) do
    Path.join(workspace_root(), sanitize_name(project.name))
    end

Just require one field which makes it easy to call this from different places even if you don't have access to a project map:

    def main_repo_path(project_name) do
    Path.join(workspace_root(), sanitize_name(project_name))
    end

## Prefer pattern matching in function heads

When a function receives a map or struct and uses multiple fields, destructure them in the function head rather than using dot-access in the body. This makes the function's contract explicit about which fields are required.

Avoid:

    def welcome_message(user) do
      "Hello #{user.name}, we'll contact you at #{user.email}"
    end

Prefer:

    def welcome_message(%{name: name, email: email}) do
      "Hello #{name}, we'll contact you at #{email}"
    end

Dot-access (`map.field`) works for atom-keyed maps and structs, but destructuring is more idiomatic — it documents the expected shape at a glance and fails fast on missing keys.

## Decouple function interfaces from caller domain knowledge

Functions should not receive foreign domain objects they must interpret. Instead, the caller should pre-compute simple, domain-agnostic flags or values and pass those. This keeps functions decoupled from unrelated domains and makes them reusable across different contexts.

Avoid — a presentation helper must understand the scheduling domain to do its job:

    def task_label(task, schedule) do
      if DateTime.compare(schedule.due_date, DateTime.utc_now()) == :lt do
        "Overdue: #{task.title}"
      else
        task.title
      end
    end

Prefer — caller resolves the cross-domain logic, function stays in its own domain:

    def task_label(title, overdue?) do
      if overdue?, do: "Overdue: #{title}", else: title
    end

    overdue? = DateTime.compare(schedule.due_date, DateTime.utc_now()) == :lt
    task_label(task.title, overdue?)

Similarly, avoid passing a struct just so the function can resolve derived data from it through other modules. Let the caller compute the value and pass it directly.

Avoid — the function must reach into the agent struct and call another module to get what it actually needs:

    def create_and_start(agent, task) do
      module_key = agent.module || "claude"
      module = CodingAgent.module_for(module_key)
      env = Enum.map(module.env_vars(), fn {k, v} -> "#{k}=#{v}" end)
      ...

Prefer — the caller resolves the env vars upfront, function receives exactly what it needs:

    def create_and_start(env_vars, task) do
      env = Enum.map(env_vars, fn {k, v} -> "#{k}=#{v}" end)
      ...

Push cross-domain interpretation to the caller and pass the result as a simple value or flag. The function should never need knowledge of unrelated domains.

## Use application config instead of `System.get_env` in application code

Read environment variables in `config/runtime.exs` and access them via `Application.get_env/2` in your modules. This keeps env var access centralized, makes testing easier (no env leaks), and follows the Elixir convention of configuring at boot.

Avoid:

    def env_vars do
      case System.get_env("API_KEY") do
        nil -> []
        key -> [{"API_KEY", key}]
      end
    end

Prefer:

    # config/runtime.exs
    config :my_app, api_key: System.get_env("API_KEY")

    # In module
    def env_vars do
      case Application.get_env(:my_app, :api_key) do
        nil -> []
        key -> [{"API_KEY", key}]
      end
    end
