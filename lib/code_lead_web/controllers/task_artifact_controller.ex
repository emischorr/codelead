defmodule CodeLeadWeb.TaskArtifactController do
  @moduledoc """
  Serves a `:folder`-target task's artifact as a zip — the download half
  of the `:artifact` finalize mode.

  The folder path is derived from the task's integer id alone, never
  from the request, so there is no traversal surface. The `project_id`
  in the path is checked only so a mismatched URL fails honestly; it is
  not authorization. There is none anywhere in the app yet, and this
  route is exactly as permissive as the LiveViews beside it.
  """
  use CodeLeadWeb, :controller

  alias CodeLead.Tasks
  alias CodeLead.Tasks.Task
  alias CodeLead.Workspace

  @doc """
  Streams the task folder as `task-<id>-<slug>.zip`.
  """
  def download(conn, %{"project_id" => project_id, "id" => id}) do
    task = Tasks.get_task!(id)
    name = "task-#{task.id}-#{Workspace.slug(task.title)}"

    with true <- to_string(task.project_id) == project_id,
         %Task{target: :folder} <- task,
         {:ok, zip} <- Workspace.archive(Workspace.task_folder(task.id), name) do
      send_download(conn, {:binary, zip},
        filename: "#{name}.zip",
        content_type: "application/zip"
      )
    else
      _no_artifact ->
        conn
        |> put_flash(:error, "This task has no downloadable artifact.")
        |> redirect(to: ~p"/projects/#{project_id}/tasks/#{id}")
    end
  end
end
