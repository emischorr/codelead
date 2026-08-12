defmodule CodeLeadWeb.ScheduleForm do
  @moduledoc """
  The "start at" field behind the schedule-run modal, as a schemaless
  changeset so `<.input>` can render its errors.

  Times are UTC end to end — entered, stored and displayed — matching
  every other timestamp the app shows (`CodeLeadWeb.Format.absolute/1`
  suffixes them all with `UTC`).

  A time already in the past is deliberately allowed through: the
  scheduler treats `scheduled_at` as a "not before" bound, so it
  dispatches immediately rather than erroring.
  """

  import Ecto.Changeset

  @types %{scheduled_at: :utc_datetime}

  @doc """
  A form for the modal, optionally seeded with submitted params.
  """
  @spec new(map()) :: Phoenix.HTML.Form.t()
  def new(params \\ %{}), do: params |> changeset() |> Phoenix.Component.to_form(as: :schedule)

  @doc """
  The submitted time, or a re-rendered form carrying the error.
  """
  @spec parse(map()) :: {:ok, DateTime.t()} | {:error, Phoenix.HTML.Form.t()}
  def parse(params) do
    changeset = changeset(params)

    case apply_action(changeset, :validate) do
      {:ok, %{scheduled_at: scheduled_at}} ->
        {:ok, scheduled_at}

      {:error, changeset} ->
        {:error, Phoenix.Component.to_form(changeset, as: :schedule)}
    end
  end

  @doc """
  Value for an input's `min` attribute — a nudge towards a future time,
  not a validation.
  """
  @spec now_input_value() :: String.t()
  def now_input_value do
    Calendar.strftime(DateTime.utc_now(), "%Y-%m-%dT%H:%M")
  end

  defp changeset(params) do
    {%{}, @types}
    |> cast(params, [:scheduled_at])
    |> validate_required([:scheduled_at])
  end
end
