defmodule Caracola.TestService do
  @moduledoc false
  use Malla.Service,
    plugins: [Caracola],
    sip: [timer_t1: 250, allow: "INVITE, ACK"]
end
