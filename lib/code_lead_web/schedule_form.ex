defmodule CodeLeadWeb.ScheduleForm do
  @moduledoc """
  The "start at" fields behind the schedule-run modal, as a schemaless
  changeset so `<.input>` can render its errors.

  The date/time is entered in the viewer's own timezone (the `.SchedulePicker`
  hook resolves it client-side, same as `.LocalTime` does for display) but
  stored in UTC (`CodeLeadWeb.Format.absolute/1` suffixes every other
  timestamp the app shows with `UTC`). There's no timezone database in this
  project, so the browser is trusted for the UTC offset — `local_at` carries
  the picked wall-clock time and `utc_offset_minutes` the offset to apply;
  `parse/1` does the actual local-to-UTC conversion.

  A time already in the past is deliberately allowed through: the
  scheduler treats `scheduled_at` as a "not before" bound, so it
  dispatches immediately rather than erroring.
  """

  import Ecto.Changeset

  @types %{local_at: :naive_datetime, utc_offset_minutes: :integer}

  @doc """
  A form for the modal, defaulting to "now" until the `.SchedulePicker`
  hook overrides it, or seeded with submitted params on re-render.
  """
  @spec new(map()) :: Phoenix.HTML.Form.t()
  def new(params \\ now_seed()),
    do: params |> changeset() |> Phoenix.Component.to_form(as: :schedule)

  @doc """
  The submitted time converted to UTC, or a re-rendered form carrying the
  error.
  """
  @spec parse(map()) :: {:ok, DateTime.t()} | {:error, Phoenix.HTML.Form.t()}
  def parse(params) do
    changeset = changeset(params)

    case apply_action(changeset, :validate) do
      {:ok, %{local_at: local_at, utc_offset_minutes: offset_minutes}} ->
        scheduled_at =
          local_at
          |> DateTime.from_naive!("Etc/UTC")
          |> DateTime.add(-offset_minutes * 60, :second)

        {:ok, scheduled_at}

      {:error, changeset} ->
        {:error, Phoenix.Component.to_form(changeset, as: :schedule)}
    end
  end

  @doc """
  Seed values for the form before the `.SchedulePicker` hook takes over —
  "now" at a UTC offset of zero, a reasonable fallback if a submit races
  ahead of the hook's `mounted()`.
  """
  @spec now_seed() :: %{local_at: String.t(), utc_offset_minutes: integer()}
  def now_seed do
    %{
      local_at: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M"),
      utc_offset_minutes: 0
    }
  end

  defp changeset(params) do
    {%{}, @types}
    |> cast(params, [:local_at, :utc_offset_minutes])
    |> validate_required([:local_at, :utc_offset_minutes])
  end
end
