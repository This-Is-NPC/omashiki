defmodule OmashikiWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias OmashikiWeb.CoreComponents

  # ---------------------------------------------------------------------------
  # <.button>
  # ---------------------------------------------------------------------------

  describe "button/1" do
    test "default kind is :primary — neon green fill on surface text" do
      html = render_component(&CoreComponents.button/1, %{inner_block: slot("Send!")})

      assert html =~ "Send!"
      assert html =~ "bg-primary-container"
      assert html =~ "text-surface"
    end

    test ":secondary renders a neutral outlined chip" do
      html =
        render_component(&CoreComponents.button/1, %{
          kind: :secondary,
          inner_block: slot("Cancel")
        })

      assert html =~ "border-outline-variant"
      assert html =~ "text-on-surface-variant"
      refute html =~ "bg-primary-container"
    end

    test ":danger pulls colour from status-failed (Omashiki red)" do
      html =
        render_component(&CoreComponents.button/1, %{
          kind: :danger,
          inner_block: slot("Delete")
        })

      assert html =~ "text-status-failed"
      assert html =~ "border-status-failed/60"
      refute html =~ "bg-primary-container"
    end

    test ":ghost lights up primary-container on hover" do
      html =
        render_component(&CoreComponents.button/1, %{
          kind: :ghost,
          inner_block: slot("Open")
        })

      assert html =~ "hover:text-primary-container"
      assert html =~ "border-outline-variant"
    end

    test "custom class is appended after the variant base" do
      html =
        render_component(&CoreComponents.button/1, %{
          class: "w-full",
          inner_block: slot("Sign in")
        })

      assert html =~ "w-full"
      assert html =~ "bg-primary-container"
    end

    test "disabled attribute reaches the rendered <button>" do
      html =
        render_component(&CoreComponents.button/1, %{
          rest: %{disabled: true},
          inner_block: slot("Disabled")
        })

      assert html =~ "disabled"
      assert html =~ "disabled:opacity-30"
    end
  end

  # ---------------------------------------------------------------------------
  # <.text_input>
  # ---------------------------------------------------------------------------

  describe "text_input/1" do
    test "renders a themed text input with token-backed border" do
      html =
        render_component(&CoreComponents.text_input/1, %{
          name: "token",
          placeholder: "Bearer token"
        })

      assert html =~ ~s(name="token")
      assert html =~ ~s(placeholder="Bearer token")
      assert html =~ "border-outline-variant"
      assert html =~ "focus:border-primary-container"
    end

    test ":mono adds font-mono" do
      html =
        render_component(&CoreComponents.text_input/1, %{
          name: "hash",
          kind: :mono
        })

      assert html =~ "font-mono"
    end

    test "default kind does not add font-mono" do
      html = render_component(&CoreComponents.text_input/1, %{name: "title"})
      refute html =~ "font-mono"
    end

    test "type override propagates to the input element" do
      html =
        render_component(&CoreComponents.text_input/1, %{
          name: "token",
          type: "password"
        })

      assert html =~ ~s(type="password")
    end
  end

  # ---------------------------------------------------------------------------
  # <.alert_banner>
  # ---------------------------------------------------------------------------

  describe "alert_banner/1" do
    test ":error pulls from status-failed tokens" do
      html =
        render_component(&CoreComponents.alert_banner/1, %{
          kind: :error,
          inner_block: slot("That token is not valid.")
        })

      assert html =~ "That token is not valid."
      assert html =~ "bg-status-failed/10"
      assert html =~ "border-status-failed/40"
      assert html =~ "text-status-failed"
    end

    test ":warning pulls from status-awaiting tokens" do
      html =
        render_component(&CoreComponents.alert_banner/1, %{
          kind: :warning,
          inner_block: slot("Awaiting human review.")
        })

      assert html =~ "bg-status-awaiting/10"
      assert html =~ "text-status-awaiting"
    end

    test ":info pulls from status-running tokens" do
      html =
        render_component(&CoreComponents.alert_banner/1, %{
          kind: :info,
          inner_block: slot("Heads up.")
        })

      assert html =~ "bg-status-running/10"
      assert html =~ "text-status-running"
    end

    test ":success pulls from status-success tokens" do
      html =
        render_component(&CoreComponents.alert_banner/1, %{
          kind: :success,
          inner_block: slot("All clear.")
        })

      assert html =~ "bg-status-success/10"
      assert html =~ "text-status-success"
    end

    test "title slot renders an uppercase eyebrow" do
      html =
        render_component(&CoreComponents.alert_banner/1, %{
          kind: :error,
          title: [%{__slot__: :title, inner_block: fn _, _ -> "Provision failed" end}],
          inner_block: slot("backend exploded")
        })

      assert html =~ "Provision failed"
      assert html =~ "uppercase"
    end

    test "no class string contains raw red/yellow/amber utilities" do
      for kind <- [:error, :warning, :info, :success] do
        html =
          render_component(&CoreComponents.alert_banner/1, %{
            kind: kind,
            inner_block: slot("body")
          })

        refute html =~ ~r/(?:^|[^-])red-\d/, "alert kind #{inspect(kind)} leaks raw red-* utility"

        refute html =~ ~r/(?:^|[^-])yellow-\d/,
               "alert kind #{inspect(kind)} leaks raw yellow-* utility"

        refute html =~ ~r/(?:^|[^-])amber-\d/,
               "alert kind #{inspect(kind)} leaks raw amber-* utility"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # button — pass-through coverage gaps
  # ---------------------------------------------------------------------------

  describe "button/1 — pass-through" do
    test "phx-disable-with reaches the rendered element" do
      html =
        render_component(&CoreComponents.button/1, %{
          rest: %{"phx-disable-with": "Saving..."},
          inner_block: slot("Save")
        })

      assert html =~ ~s(phx-disable-with="Saving...")
    end

    test "phx-click reaches the rendered element" do
      html =
        render_component(&CoreComponents.button/1, %{
          rest: %{"phx-click": "submit"},
          inner_block: slot("Go")
        })

      assert html =~ ~s(phx-click="submit")
    end

    test "data-confirm reaches the rendered element" do
      html =
        render_component(&CoreComponents.button/1, %{
          rest: %{"data-confirm": "Are you sure?"},
          inner_block: slot("Delete")
        })

      assert html =~ ~s(data-confirm="Are you sure?")
    end
  end

  # ---------------------------------------------------------------------------
  # text_input — pass-through coverage gaps
  # ---------------------------------------------------------------------------

  describe "text_input/1 — pass-through" do
    test "required attr reaches the rendered element" do
      html =
        render_component(&CoreComponents.text_input/1, %{
          name: "email",
          rest: %{required: true}
        })

      assert html =~ "required"
    end

    test "type=email reaches the rendered element" do
      html =
        render_component(&CoreComponents.text_input/1, %{
          name: "email",
          type: "email"
        })

      assert html =~ ~s(type="email")
    end

    test "custom class is appended after the theme base" do
      html =
        render_component(&CoreComponents.text_input/1, %{
          name: "tag",
          class: "uppercase"
        })

      assert html =~ "uppercase"
      assert html =~ "border-outline-variant"
    end
  end

  # ---------------------------------------------------------------------------
  # alert_banner — actions slot
  # ---------------------------------------------------------------------------

  describe "alert_banner/1 — actions slot" do
    test ":actions renders alongside the body" do
      html =
        render_component(&CoreComponents.alert_banner/1, %{
          kind: :info,
          inner_block: slot("body"),
          actions: [%{__slot__: :actions, inner_block: fn _, _ -> "Resolve" end}]
        })

      assert html =~ "Resolve"
      assert html =~ "body"
    end
  end

  # ---------------------------------------------------------------------------
  # Render-shape tests for the rest of the public surface
  # ---------------------------------------------------------------------------

  describe "label/1" do
    test "renders a <label> with the for= attr" do
      html =
        render_component(&CoreComponents.label/1, %{
          for: "user_email",
          inner_block: slot("Email")
        })

      assert html =~ ~s(for="user_email")
      assert html =~ "Email"
    end
  end

  describe "error/1" do
    test "renders the inner block with the rose error tone" do
      html = render_component(&CoreComponents.error/1, %{inner_block: slot("required")})
      assert html =~ "required"
      assert html =~ "text-rose-600"
    end
  end

  describe "header/1" do
    test "renders the title and subtitle slots" do
      html =
        render_component(&CoreComponents.header/1, %{
          inner_block: slot("Account"),
          subtitle: [%{__slot__: :subtitle, inner_block: fn _, _ -> "manage settings" end}],
          actions: []
        })

      assert html =~ "Account"
      assert html =~ "manage settings"
    end
  end

  describe "back/1" do
    test "renders an arrow-left icon and the inner-block label" do
      html =
        render_component(&CoreComponents.back/1, %{
          navigate: "/",
          inner_block: slot("Back to overview")
        })

      assert html =~ "Back to overview"
      assert html =~ ~s(href="/")
      assert html =~ "hero-arrow-left-solid"
    end
  end

  describe "icon/1" do
    test "renders heroicon name as a class on the span" do
      html = render_component(&CoreComponents.icon/1, %{name: "hero-x-mark-solid"})
      assert html =~ "hero-x-mark-solid"
    end

    test "appends user class after the icon name" do
      html =
        render_component(&CoreComponents.icon/1, %{
          name: "hero-arrow-path",
          class: "h-3 w-3 animate-spin"
        })

      assert html =~ "hero-arrow-path"
      assert html =~ "h-3 w-3 animate-spin"
    end
  end

  describe "input/1 — variants" do
    test "checkbox renders the hidden + checkbox pair" do
      html =
        render_component(&CoreComponents.input/1, %{
          type: "checkbox",
          name: "agree",
          label: "I agree",
          checked: true
        })

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(type="checkbox")
      assert html =~ "I agree"
    end

    test "select renders the option block" do
      html =
        render_component(&CoreComponents.input/1, %{
          type: "select",
          name: "role",
          label: "Role",
          options: [{"Admin", "admin"}, {"Viewer", "viewer"}],
          value: "admin",
          prompt: "Pick one"
        })

      assert html =~ "<select"
      assert html =~ "Admin"
      assert html =~ "Viewer"
      assert html =~ "Pick one"
    end

    test "textarea renders the textarea element" do
      html =
        render_component(&CoreComponents.input/1, %{
          type: "textarea",
          name: "notes",
          label: "Notes",
          value: "hello"
        })

      assert html =~ "<textarea"
      assert html =~ "hello"
    end

    test "default text input renders an <input type='text'> with label" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "name",
          label: "Name",
          value: "Ada"
        })

      assert html =~ ~s(type="text")
      assert html =~ "Name"
      assert html =~ "Ada"
    end

    test "errors slot translates and shows error copy" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "name",
          label: "Name",
          value: "",
          errors: ["can't be blank"]
        })

      assert html =~ "can&#39;t be blank"
    end
  end

  describe "modal/1" do
    test "renders the dialog wrapper with the given id" do
      html =
        render_component(&CoreComponents.modal/1, %{
          id: "confirm-modal",
          inner_block: slot("Are you sure?")
        })

      assert html =~ ~s(id="confirm-modal")
      assert html =~ "Are you sure?"
      assert html =~ ~s(role="dialog")
    end

    test "show=true triggers phx-mounted" do
      html =
        render_component(&CoreComponents.modal/1, %{
          id: "m1",
          show: true,
          inner_block: slot("body")
        })

      assert html =~ "phx-mounted"
    end
  end

  describe "flash/1" do
    test "info kind renders the title and message" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          title: "Heads up",
          inner_block: slot("Network is back")
        })

      assert html =~ "Heads up"
      assert html =~ "Network is back"
      assert html =~ "border-primary-container"
    end

    test "error kind paints the failed border" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :error,
          title: "Whoops",
          inner_block: slot("Something broke")
        })

      assert html =~ "border-status-failed"
    end
  end

  describe "flash_group/1" do
    test "renders both info and error wrappers + connection-state flashes" do
      html = render_component(&CoreComponents.flash_group/1, %{flash: %{}})
      assert html =~ ~s(id="client-error")
      assert html =~ ~s(id="server-error")
      assert html =~ "Attempting to reconnect"
    end
  end

  describe "table/1" do
    test "renders a row per entry with the column slots" do
      html =
        render_component(&CoreComponents.table/1, %{
          id: "users",
          rows: [%{id: 1, name: "Ada"}, %{id: 2, name: "Linus"}],
          col: [
            %{
              __slot__: :col,
              label: "id",
              inner_block: fn _, row -> Integer.to_string(row.id) end
            },
            %{
              __slot__: :col,
              label: "name",
              inner_block: fn _, row -> row.name end
            }
          ],
          action: []
        })

      assert html =~ "Ada"
      assert html =~ "Linus"
      assert html =~ "id"
      assert html =~ "name"
    end
  end

  describe "list/1" do
    test "renders one row per item with title + body" do
      html =
        render_component(&CoreComponents.list/1, %{
          item: [
            %{__slot__: :item, title: "Title", inner_block: fn _, _ -> "Value 1" end},
            %{__slot__: :item, title: "Views", inner_block: fn _, _ -> "42" end}
          ]
        })

      assert html =~ "Title"
      assert html =~ "Value 1"
      assert html =~ "Views"
      assert html =~ "42"
    end
  end

  describe "JS commands" do
    test "show/1 returns a JS struct that targets the selector" do
      js = CoreComponents.show("#welcome")
      assert %Phoenix.LiveView.JS{} = js
    end

    test "hide/1 returns a JS struct that targets the selector" do
      js = CoreComponents.hide("#welcome")
      assert %Phoenix.LiveView.JS{} = js
    end

    test "show_modal/1 returns a JS struct" do
      js = CoreComponents.show_modal("welcome")
      assert %Phoenix.LiveView.JS{} = js
    end

    test "hide_modal/1 returns a JS struct" do
      js = CoreComponents.hide_modal("welcome")
      assert %Phoenix.LiveView.JS{} = js
    end
  end

  describe "translate_errors/2" do
    test "filters and translates errors for a given field" do
      errors = [
        {:name, {"can't be blank", []}},
        {:email, {"is invalid", []}}
      ]

      assert CoreComponents.translate_errors(errors, :name) == ["can't be blank"]
      assert CoreComponents.translate_errors(errors, :email) == ["is invalid"]
      assert CoreComponents.translate_errors(errors, :missing) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp slot(text) do
    [%{__slot__: :inner_block, inner_block: fn _, _ -> text end}]
  end
end
