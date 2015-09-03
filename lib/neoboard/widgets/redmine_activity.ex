defmodule Neoboard.Widgets.RedmineActivity do
  use GenServer
  use Neoboard.Pusher
  use Neoboard.Config
  use Timex
  alias Neoboard.Widgets.RedmineActivity.Parser

  def start_link do
    {:ok, pid} = GenServer.start_link(__MODULE__, nil)
    send(pid, :tick)
    :timer.send_interval(config[:every], pid, :tick)
    {:ok, pid}
  end

  def handle_info(:tick, _) do
    {:ok, response} = fetch
    push! response
    {:noreply, nil}
  end

  defp fetch do
    HTTPoison.start
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} = HTTPoison.get(config[:url])
    response = process_body(body) |> build_response
    {:ok, response}
  end

  defp process_body(body) do
    Parser.parse!(body)
  end

  defp build_response(%{projects: projects, users: users}) do
    %{
      projects: Enum.map(projects, &(%{&1 | updated_at: DateFormat.format!(&1.updated_at, "{ISO}")})),
      users: users
    }
  end
end

defmodule Neoboard.Widgets.RedmineActivity.Project do
  use Timex
  alias Neoboard.Widgets.RedmineActivity.Project
  defstruct name: nil, users: [], activity: 0, updated_at: nil

  def add_user(project, user) do
    users = Enum.uniq([user | project.users], &(&1.email))
    %{project | users: users}
  end

  def add_activity(project) do
    %{project | activity: project.activity + 1}
  end

  def updated_at(project, datetime_as_string) do
    {:ok, date} = DateFormat.parse(datetime_as_string, "{ISOz}")
    at = cond do
     is_nil(project.updated_at) -> date
     project.updated_at < date  -> date
     true -> project.updated_at
    end
    %{project | updated_at: at}
  end

  def compare(a, b) do
    a.activity > b.activity
  end
end

defmodule Neoboard.Widgets.RedmineActivity.User do
  alias Neoboard.Widgets.RedmineActivity.User
  defstruct name: nil, email: nil, avatar: nil, projects: []

  def build(email, name, project) do
    %User{name: name, email: email, avatar: avatar_from_email(email), projects: [project]}
  end

  def add_projects(user, projects) do
    projects = Enum.uniq(user.projects ++ projects)
    %{user | projects: projects}
  end

  defp avatar_from_email(email) do
    hash = :erlang.md5(email) |> Base.encode16(case: :lower)
    "https://www.gravatar.com/avatar/" <> hash
  end
end

defmodule Neoboard.Widgets.RedmineActivity.Parser do
  alias Neoboard.Widgets.RedmineActivity.Xml
  alias Neoboard.Widgets.RedmineActivity.Project
  alias Neoboard.Widgets.RedmineActivity.User

  def parse!(source) do
    projects =
      Xml.load_xml(source)
      |> parse_activities
      |> collect_projects
    %{
      projects: projects,
      users: collect_users(projects)
    }
  end

  defp parse_activities(doc) do
    Xml.xpath(doc, '/feed/entry')
    |> Enum.reduce(%{}, &reduce_project/2)
  end

  defp collect_projects(actitivities) do
    Dict.values(actitivities)
    |> Enum.sort(&Project.compare/2)
  end

  defp collect_users(projects) do
    projects
    |> Enum.map(&(&1.users))
    |> List.flatten
    |> Enum.reduce(%{}, fn (user, all) ->
      u = Dict.get(all, user.email, user)
      Dict.put(all, user.email, User.add_projects(u, user.projects))
    end)
    |> Dict.values
  end

  defp reduce_project(entry, dict) do
    project = extract_project(entry)
    reduced =
      Dict.get(dict, project.name, project)
      |> Project.add_user(extract_user(entry))
      |> Project.add_activity
      |> Project.updated_at(extract_updated(entry))
    Dict.put(dict, project.name, reduced)
  end

  defp extract_project(entry) do
    %Project{name: extract_project_name(entry)}
  end

  defp extract_user(entry) do
    author = entry  |> Xml.first('./author')
    name   = author |> Xml.first('./name')  |> Xml.text
    email  = author |> Xml.first('./email') |> Xml.text
    User.build(email, name, extract_project_name(entry))
  end

  defp extract_project_name(entry) do
    entry |> Xml.first('./title') |> Xml.text |> match(~r/^([\w\-_ ]+) - /)
  end

  defp extract_updated(entry) do
    entry |> Xml.first('./updated') |> Xml.text
  end

  defp match(nil, _regxp), do: nil
  defp match(text, regxp) do
    Regex.run(regxp, text, capture: :all_but_first)
    |> List.first
  end
end

defmodule Neoboard.Widgets.RedmineActivity.Xml do
  require Record
  Record.defrecord :xmlAttribute, Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  Record.defrecord :xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  Record.defrecord :xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")

  def load_xml(source) do
    {xml, _rest} = :xmerl_scan.string(:binary.bin_to_list(source))
    xml
  end

  def xpath(nil, _), do: []
  def xpath(node, path) do
    :xmerl_xpath.string(to_char_list(path), node)
  end
  def first(node, path), do: node |> xpath(path) |> List.first

  def text(node), do: node |> xpath('./text()') |> extract_text
  defp extract_text([xmlText(value: value)]), do: List.to_string(value)
  defp extract_text([xmlText(value: value) | _x]), do: List.to_string(value)
  defp extract_text(xmlText(value: value)), do: List.to_string(value)
  defp extract_text([]), do: ""
end
