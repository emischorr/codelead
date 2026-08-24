defmodule CodeLeadWeb.ScheduleFormTest do
  use ExUnit.Case, async: true

  alias CodeLeadWeb.ScheduleForm

  describe "parse/1" do
    test "offset zero keeps the naive time as-is (UTC)" do
      assert {:ok, ~U[2026-08-24 14:00:00Z]} =
               ScheduleForm.parse(%{
                 "local_at" => "2026-08-24T14:00",
                 "utc_offset_minutes" => "0"
               })
    end

    test "a positive offset (zone behind UTC) adds minutes to reach UTC" do
      # 14:00 in a zone 120 minutes behind UTC (e.g. Europe/Berlin, CEST) is 12:00 UTC.
      assert {:ok, ~U[2026-08-24 12:00:00Z]} =
               ScheduleForm.parse(%{
                 "local_at" => "2026-08-24T14:00",
                 "utc_offset_minutes" => "120"
               })
    end

    test "a negative offset (zone ahead of UTC) subtracts minutes to reach UTC" do
      # 14:00 in a zone 240 minutes ahead of UTC (e.g. America/New_York, EDT) is 18:00 UTC.
      assert {:ok, ~U[2026-08-24 18:00:00Z]} =
               ScheduleForm.parse(%{
                 "local_at" => "2026-08-24T14:00",
                 "utc_offset_minutes" => "-240"
               })
    end

    test "a blank local_at keeps the form around with an error" do
      assert {:error, form} =
               ScheduleForm.parse(%{"local_at" => "", "utc_offset_minutes" => "0"})

      assert form[:local_at].errors != []
    end

    test "a missing utc_offset_minutes keeps the form around with an error" do
      assert {:error, form} = ScheduleForm.parse(%{"local_at" => "2026-08-24T14:00"})

      assert form[:utc_offset_minutes].errors != []
    end
  end

  describe "new/1" do
    test "defaults to now at offset zero" do
      form = ScheduleForm.new()

      assert %NaiveDateTime{} = form[:local_at].value
      assert form[:utc_offset_minutes].value == 0
    end
  end
end
