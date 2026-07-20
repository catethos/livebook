defmodule LivebookWeb.DevController do
  use LivebookWeb, :controller

  alias Livebook.{LiveMarkdown, Notebook, Session}
  alias Livebook.Notebook.Cell
  alias Livebook.Text.Delta

  plug :disallow_browser
  plug :require_enabled

  def sync(conn, %{"file" => path}) when is_binary(path) do
    file = Livebook.FileSystem.File.local(path)

    session =
      Livebook.Sessions.list_sessions()
      |> Enum.find(fn session ->
        session.file != nil and Livebook.FileSystem.File.equal?(session.file, file)
      end)

    if session do
      Livebook.Session.sync_file(session.pid)
      json(conn, %{status: "ok"})
    else
      conn
      |> put_status(404)
      |> json(%{status: "error", message: "No session found for the given file"})
    end
  end

  def open(conn, %{"file" => path}) when is_binary(path) do
    file = Livebook.FileSystem.File.local(path)

    session =
      Livebook.Sessions.list_sessions()
      |> Enum.find(fn session ->
        session.file != nil and Livebook.FileSystem.File.equal?(session.file, file)
      end)

    if session do
      json(conn, %{path: ~p"/sessions/#{session.id}"})
    else
      case Livebook.FileSystem.File.read(file) do
        {:ok, content} ->
          {notebook, _} = LiveMarkdown.notebook_from_livemd(content)

          {:ok, session} =
            Livebook.Sessions.create_session(
              notebook: notebook,
              file: file,
              origin: {:file, file}
            )

          json(conn, %{path: ~p"/sessions/#{session.id}"})

        {:error, reason} ->
          conn
          |> put_status(422)
          |> json(%{status: "error", message: "Failed to read file: #{reason}"})
      end
    end
  end

  def cells(conn, %{"file" => path}) when is_binary(path) do
    case fetch_session_by_file(path) do
      {:ok, session} ->
        data = Session.get_data(session.pid)

        sections =
          Enum.map(Notebook.all_sections(data.notebook), fn section ->
            %{
              id: section.id,
              name: section.name,
              cells: Enum.map(section.cells, &cell_info(&1, data.cell_infos))
            }
          end)

        json(conn, %{status: "ok", path: ~p"/sessions/#{session.id}", sections: sections})

      {:error, :session_not_found} ->
        error(conn, 404, "No session found for the given file")
    end
  end

  def insert_cell(conn, %{"file" => path, "section_id" => section_id, "type" => type} = params)
      when is_binary(path) and is_binary(section_id) and type in ["code", "markdown"] do
    with {:ok, session} <- fetch_session_by_file(path),
         data <- Session.get_data(session.pid),
         {:ok, section} <- Notebook.fetch_section(data.notebook, section_id),
         {:ok, index} <- insertion_index(section, params["after_cell_id"]) do
      cell_id = Livebook.Utils.random_id()
      attrs = %{source: params["source"] || ""}

      Session.insert_cell(
        session.pid,
        section_id,
        index,
        String.to_existing_atom(type),
        attrs,
        cell_id
      )

      Session.get_data(session.pid)
      json(conn, %{status: "ok", cell_id: cell_id})
    else
      {:error, :session_not_found} -> error(conn, 404, "No session found for the given file")
      :error -> error(conn, 404, "No section found for the given section_id")
      {:error, :cell_not_found} -> error(conn, 404, "No cell found for the given after_cell_id")
    end
  end

  def update_cell(conn, %{"file" => path, "cell_id" => cell_id, "source" => source})
      when is_binary(path) and is_binary(cell_id) and is_binary(source) do
    with {:ok, session} <- fetch_session_by_file(path),
         data <- Session.get_data(session.pid),
         {:ok, cell, _section} <- Notebook.fetch_cell_and_section(data.notebook, cell_id) do
      revision = data.cell_infos[cell_id].sources.primary.revision

      Session.apply_cell_delta(
        session.pid,
        cell_id,
        :primary,
        Delta.diff(cell.source, source),
        nil,
        revision
      )

      Session.get_data(session.pid)
      json(conn, %{status: "ok", cell_id: cell_id})
    else
      {:error, :session_not_found} -> error(conn, 404, "No session found for the given file")
      :error -> error(conn, 404, "No cell found for the given cell_id")
    end
  end

  def delete_cell(conn, %{"file" => path, "cell_id" => cell_id})
      when is_binary(path) and is_binary(cell_id) do
    with {:ok, session} <- fetch_session_by_file(path),
         data <- Session.get_data(session.pid),
         {:ok, _cell, _section} <- Notebook.fetch_cell_and_section(data.notebook, cell_id) do
      Session.delete_cell(session.pid, cell_id)
      Session.get_data(session.pid)
      json(conn, %{status: "ok", cell_id: cell_id})
    else
      {:error, :session_not_found} -> error(conn, 404, "No session found for the given file")
      :error -> error(conn, 404, "No cell found for the given cell_id")
    end
  end

  def evaluate(conn, %{"file" => path, "cell_id" => cell_id})
      when is_binary(path) and is_binary(cell_id) do
    with {:ok, session} <- fetch_session_by_file(path),
         data <- Session.get_data(session.pid),
         {:ok, cell, _section} <- Notebook.fetch_cell_and_section(data.notebook, cell_id),
         true <- Cell.evaluable?(cell) do
      Session.queue_cell_evaluation(session.pid, cell_id)

      conn
      |> put_status(202)
      |> json(%{status: "accepted", cell_id: cell_id})
    else
      {:error, :session_not_found} ->
        error(conn, 404, "No session found for the given file")

      :error ->
        error(conn, 404, "No cell found for the given cell_id")

      false ->
        error(conn, 422, "The specified cell is not evaluable")
    end
  end

  def restamp(conn, %{"old_source" => old_source, "new_source" => new_source})
      when is_binary(old_source) and is_binary(new_source) do
    {notebook_before, %{has_stamp?: has_stamp?, stamp_verified?: stamp_verified?}} =
      LiveMarkdown.notebook_from_livemd(old_source)

    if has_stamp? and not stamp_verified? do
      conn
      |> put_status(422)
      |> json(%{status: "error", message: "The old_source stamp is invalid"})
    else
      {notebook_after, %{stamp_verified?: new_stamp_verified?}} =
        LiveMarkdown.notebook_from_livemd(new_source)

      if new_stamp_verified? do
        json(conn, %{source: new_source})
      else
        stamp_metadata = LiveMarkdown.Export.notebook_stamp_metadata(notebook_before)
        notebook_after = LiveMarkdown.Import.apply_stamp_metadata(notebook_after, stamp_metadata)

        {source, _warnings} = LiveMarkdown.notebook_to_livemd(notebook_after)

        json(conn, %{source: source})
      end
    end
  end

  defp fetch_session_by_file(path) do
    file = Livebook.FileSystem.File.local(path)

    case Enum.find(Livebook.Sessions.list_sessions(), fn session ->
           session.file != nil and Livebook.FileSystem.File.equal?(session.file, file)
         end) do
      nil -> {:error, :session_not_found}
      session -> {:ok, session}
    end
  end

  defp insertion_index(section, nil), do: {:ok, length(section.cells)}

  defp insertion_index(section, cell_id) when is_binary(cell_id) do
    case Enum.find_index(section.cells, &(&1.id == cell_id)) do
      nil -> {:error, :cell_not_found}
      index -> {:ok, index + 1}
    end
  end

  defp cell_info(cell, cell_infos) do
    info = %{
      id: cell.id,
      type: Cell.type(cell),
      source: cell.source
    }

    case cell_infos[cell.id] do
      %{eval: eval} ->
        Map.put(info, :evaluation, %{
          status: eval.status,
          validity: eval.validity,
          errored: eval.errored,
          interrupted: eval.interrupted,
          evaluation_number: eval.evaluation_number,
          evaluation_time_ms: eval.evaluation_time_ms
        })

      _ ->
        info
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{status: "error", message: message})
  end

  defp disallow_browser(conn, _opts) do
    if get_req_header(conn, "origin") == [] do
      conn
    else
      conn
      |> put_status(403)
      |> json(%{status: "error", message: "This endpoint is not available in the browser"})
      |> halt()
    end
  end

  defp require_enabled(conn, _opts) do
    if Livebook.Settings.dev_endpoints_enabled?() do
      conn
    else
      conn
      |> put_status(403)
      |> json(%{
        status: "error",
        message: "Dev endpoints are disabled, you can enable them in the settings"
      })
      |> halt()
    end
  end
end
