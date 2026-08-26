defmodule OmashikiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use OmashikiWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint OmashikiWeb.Endpoint

      use OmashikiWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import OmashikiWeb.ConnCase
      import Omashiki.Fixtures
    end
  end

  setup tags do
    Omashiki.DataCase.setup_sandbox(tags)
    Omashiki.DataCase.setup_config()

    {conn, ctx} =
      Phoenix.ConnTest.build_conn()
      |> OmashikiWeb.ConnCase.maybe_authenticate(tags)

    {:ok, [conn: conn] ++ ctx}
  end

  @label_attributes ~w(alt aria-label placeholder title)

  @doc """
  Returns only the words a human (or a screen reader) actually reads in a
  rendered document: text nodes plus #{Enum.join(@label_attributes, ", ")}.

  Markup, `<script>` bodies, and every other attribute are dropped, so the
  generated CSRF and LiveView session tokens cannot be mistaken for
  vocabulary. Use this, never the raw HTML, when refuting that a word is
  absent from a screen: a base64url token contains arbitrary letter runs
  and will otherwise match at random.
  """
  def visible_text(html) when is_binary(html) do
    document = Floki.parse_document!(html)

    labels =
      Enum.flat_map(@label_attributes, fn attribute ->
        Floki.attribute(document, "[#{attribute}]", attribute)
      end)

    Enum.join([Floki.text(document, sep: " ") | labels], " ")
  end

  @doc """
  Adds the bearer-token header AND a `:user_id` session cookie to the
  given conn unless the test is tagged `:unauthenticated`.

  The header authenticates REST/MCP requests via `BearerAuth`; the
  session value authenticates LiveView mounts via `AuthHooks`.

  Returns `{conn, ctx}` where `ctx` is `[user: user, token: token,
  token_plaintext: plaintext]` on authenticated tests, or `[]` for
  unauthenticated ones.
  """
  def maybe_authenticate(conn, %{unauthenticated: true}), do: {conn, []}

  def maybe_authenticate(conn, _tags) do
    user = Omashiki.Fixtures.user_fixture()
    {token, plaintext} = Omashiki.Fixtures.api_token_fixture(user)

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{plaintext}")
      |> Plug.Test.init_test_session(%{"user_id" => user.id})

    {conn, user: user, token: token, token_plaintext: plaintext}
  end
end
