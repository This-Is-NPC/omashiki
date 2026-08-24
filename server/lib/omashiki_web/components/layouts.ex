defmodule OmashikiWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use OmashikiWeb, :controller` and
  `use OmashikiWeb, :live_view`.
  """
  use OmashikiWeb, :html

  embed_templates "layouts/*"

  @doc "Resolve the global-nav link class for an operator surface."
  def nav_link_class(target, assigns) do
    base = "font-label text-label-md tracking-[0.3em] uppercase transition-colors pb-1 border-b"

    if assigns[:active_tab] == target do
      "#{base} text-primary-container border-primary-container"
    else
      "#{base} text-on-surface-variant border-transparent hover:text-primary-container"
    end
  end
end
