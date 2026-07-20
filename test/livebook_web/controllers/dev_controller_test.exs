defmodule LivebookWeb.DevControllerTest do
  use LivebookWeb.ConnCase, async: true

  alias Livebook.{Sessions, Session, FileSystem}

  setup do
    Livebook.Settings.set_dev_endpoints_enabled(true)
    on_exit(fn -> Livebook.Settings.set_dev_endpoints_enabled(false) end)
  end

  test "rejects requests with origin header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:4000")
      |> post(~p"/dev/sync", %{file: "/some/path"})

    assert json_response(conn, 403) == %{
             "status" => "error",
             "message" => "This endpoint is not available in the browser"
           }
  end

  test "rejects requests when dev endpoints are disabled", %{conn: conn} do
    Livebook.Settings.set_dev_endpoints_enabled(false)

    conn = post(conn, ~p"/dev/sync", %{file: "/some/path"})

    assert json_response(conn, 403) == %{
             "status" => "error",
             "message" => "Dev endpoints are disabled, you can enable them in the settings"
           }
  end

  describe "sync" do
    @tag :tmp_dir
    test "syncs the session when it exists for the given file", %{conn: conn, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      {:ok, session} = Sessions.create_session(file: file)

      on_exit(fn -> Session.close(session.pid) end)

      :ok =
        FileSystem.File.write(file, """
        # My notebook

        ## Section

        Hello world!
        """)

      conn = post(conn, ~p"/dev/sync", %{file: file.path})

      assert json_response(conn, 200) == %{"status" => "ok"}

      assert %{notebook: %{name: "My notebook"}} = Session.get_data(session.pid)
    end

    @tag :tmp_dir
    test "returns error when no session exists for the given file",
         %{conn: conn, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      conn = post(conn, ~p"/dev/sync", %{file: file.path})

      assert json_response(conn, 404) == %{
               "status" => "error",
               "message" => "No session found for the given file"
             }
    end
  end

  describe "open" do
    @tag :tmp_dir
    test "returns the existing session path when a session with the file already exists",
         %{conn: conn, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      {:ok, session} = Sessions.create_session(file: file)

      on_exit(fn -> Session.close(session.pid) end)

      conn = post(conn, ~p"/dev/open", %{file: file.path})

      assert json_response(conn, 200) == %{"path" => ~p"/sessions/#{session.id}"}
    end

    @tag :tmp_dir
    test "creates a new session and returns its path when no session exists",
         %{conn: conn, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      file = FileSystem.File.resolve(tmp_dir, "notebook.livemd")

      :ok =
        FileSystem.File.write(file, """
        # My notebook

        ## Section

        ```elixir
        :ok
        ```
        """)

      conn = post(conn, ~p"/dev/open", %{file: file.path})

      assert %{"path" => "/sessions/" <> session_id} = json_response(conn, 200)

      {:ok, session} = Sessions.fetch_session(session_id)
      assert session.file == file
      assert %{notebook: %{name: "My notebook"}} = Session.get_data(session.pid)

      Session.close(session.pid)
    end

    @tag :tmp_dir
    test "returns error when the file does not exist", %{conn: conn, tmp_dir: tmp_dir} do
      tmp_dir = FileSystem.File.local(tmp_dir <> "/")
      file = FileSystem.File.resolve(tmp_dir, "nonexistent.livemd")

      conn = post(conn, ~p"/dev/open", %{file: file.path})

      assert json_response(conn, 422) == %{
               "status" => "error",
               "message" => "Failed to read file: no such file or directory"
             }
    end
  end

  describe "cells" do
    @tag :tmp_dir
    test "returns the current notebook structure and evaluation state", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      file = FileSystem.File.local(Path.join(tmp_dir, "notebook.livemd"))

      :ok =
        FileSystem.File.write(file, """
        # My notebook

        ## Calculation

        Some explanation.

        ```elixir
        40 + 2
        ```
        """)

      open_conn = post(conn, ~p"/dev/open", %{file: file.path})
      assert %{"path" => "/sessions/" <> session_id} = json_response(open_conn, 200)

      conn = post(recycle(conn), ~p"/dev/cells", %{file: file.path})

      assert %{
               "status" => "ok",
               "path" => "/sessions/" <> ^session_id,
               "sections" => sections
             } = json_response(conn, 200)

      assert [
               %{
                 "name" => "Setup",
                 "cells" => [%{"id" => "setup", "type" => "code"}]
               },
               %{
                 "name" => "Calculation",
                 "cells" => [
                   %{"type" => "markdown", "source" => "Some explanation."},
                   %{
                     "type" => "code",
                     "source" => "40 + 2",
                     "evaluation" => %{
                       "status" => "ready",
                       "validity" => "fresh",
                       "evaluation_number" => 0
                     }
                   }
                 ]
               }
             ] = sections

      {:ok, session} = Sessions.fetch_session(session_id)
      Session.close(session.pid)
    end

    @tag :tmp_dir
    test "returns error when no session exists for the given file", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "notebook.livemd")
      conn = post(conn, ~p"/dev/cells", %{file: path})

      assert json_response(conn, 404) == %{
               "status" => "error",
               "message" => "No session found for the given file"
             }
    end
  end

  describe "evaluate" do
    @tag :tmp_dir
    test "queues an evaluable cell", %{conn: conn, tmp_dir: tmp_dir} do
      file = FileSystem.File.local(Path.join(tmp_dir, "notebook.livemd"))

      :ok =
        FileSystem.File.write(file, """
        # My notebook

        ## Calculation

        ```elixir
        40 + 2
        ```
        """)

      open_conn = post(conn, ~p"/dev/open", %{file: file.path})
      assert %{"path" => "/sessions/" <> session_id} = json_response(open_conn, 200)
      {:ok, session} = Sessions.fetch_session(session_id)

      %{notebook: notebook} = Session.get_data(session.pid)
      [section] = notebook.sections
      [cell] = section.cells

      conn = post(recycle(conn), ~p"/dev/evaluate", %{file: file.path, cell_id: cell.id})

      assert json_response(conn, 202) == %{
               "status" => "accepted",
               "cell_id" => cell.id
             }

      assert Session.get_data(session.pid).cell_infos[cell.id].eval.status in [
               :queued,
               :evaluating
             ]

      Session.close(session.pid)
    end

    @tag :tmp_dir
    test "rejects missing and non-evaluable cells", %{conn: conn, tmp_dir: tmp_dir} do
      file = FileSystem.File.local(Path.join(tmp_dir, "notebook.livemd"))

      :ok =
        FileSystem.File.write(file, """
        # My notebook

        ## Notes

        Explanation only.
        """)

      open_conn = post(conn, ~p"/dev/open", %{file: file.path})
      assert %{"path" => "/sessions/" <> session_id} = json_response(open_conn, 200)
      {:ok, session} = Sessions.fetch_session(session_id)
      [section] = Session.get_data(session.pid).notebook.sections
      [cell] = section.cells

      missing_conn =
        post(recycle(conn), ~p"/dev/evaluate", %{file: file.path, cell_id: "missing"})

      assert json_response(missing_conn, 404) == %{
               "status" => "error",
               "message" => "No cell found for the given cell_id"
             }

      markdown_conn =
        post(recycle(conn), ~p"/dev/evaluate", %{file: file.path, cell_id: cell.id})

      assert json_response(markdown_conn, 422) == %{
               "status" => "error",
               "message" => "The specified cell is not evaluable"
             }

      Session.close(session.pid)
    end
  end

  describe "restamp" do
    test "returns new_source content as is if old_source has no stamp", %{conn: conn} do
      old_source = """
      # Notebook before

      ## Section

      ```elixir
      :original
      ```
      """

      new_source = """
      # Notebook after

      ## Section

      ```elixir
      :changed
      ```
      """

      conn =
        post(conn, ~p"/dev/restamp", %{
          old_source: old_source,
          new_source: new_source
        })

      assert %{"source" => source} = json_response(conn, 200)
      assert source == new_source
    end

    test "returns error when old_source has an invalid stamp", %{conn: conn} do
      old_source = """
      # Notebook before

      ## Section

      <!-- livebook:{"offset":61,"stamp":"invalid_stamp"} -->
      """

      conn =
        post(conn, ~p"/dev/restamp", %{
          old_source: old_source,
          new_source: "# Notebook after\n"
        })

      assert json_response(conn, 422) == %{
               "status" => "error",
               "message" => "The old_source stamp is invalid"
             }
    end

    test "returns new_source unchanged when it already has a valid stamp", %{conn: conn} do
      notebook = %{
        Livebook.Notebook.new()
        | hub_id: "personal-hub",
          hub_secret_names: ["MY_SECRET"]
      }

      {old_source, _} = Livebook.LiveMarkdown.notebook_to_livemd(notebook)
      {new_source, _} = Livebook.LiveMarkdown.notebook_to_livemd(notebook)

      conn =
        post(conn, ~p"/dev/restamp", %{
          old_source: old_source,
          new_source: new_source
        })

      assert json_response(conn, 200) == %{"source" => new_source}
    end

    test "returns stamped new_source preserving metadata from old_source", %{conn: conn} do
      notebook_before = %{
        Livebook.Notebook.new()
        | hub_id: "personal-hub",
          hub_secret_names: ["MY_SECRET"]
      }

      {old_source, _} = Livebook.LiveMarkdown.notebook_to_livemd(notebook_before)

      new_source = """
      # Updated notebook

      ## Section

      Hello world!
      """

      conn =
        post(conn, ~p"/dev/restamp", %{
          old_source: old_source,
          new_source: new_source
        })

      assert %{"source" => source} = json_response(conn, 200)

      assert source =~ "# Updated notebook"

      # Verify the returned source has valid stamp with the same metadata.
      {notebook, _} = Livebook.LiveMarkdown.notebook_from_livemd(source)
      assert %{hub_id: "personal-hub", hub_secret_names: ["MY_SECRET"]} = notebook
    end
  end
end
