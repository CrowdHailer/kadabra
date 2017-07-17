defmodule Kadabra.Frame.Continuation do
  defstruct [:header_block_fragment, end_headers: false]

  @type t :: %__MODULE__{
    end_headers: boolean,
    header_block_fragment: bitstring
  }

  alias Kadabra.Frame.Flags

  @spec new(Kadabra.Frame.t) :: t
  def new(%{payload: payload, flags: flags}) do
    %__MODULE__{
      header_block_fragment: payload,
      end_headers: Flags.end_headers?(flags)
    }
  end
end
