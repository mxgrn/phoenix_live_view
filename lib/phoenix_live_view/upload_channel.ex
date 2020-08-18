defmodule Phoenix.LiveView.UploadChannel do
  @moduledoc false
  use Phoenix.Channel, log: false

  require Logger

  alias Phoenix.LiveView.{Static, Channel}

  @impl true
  def join(_topic, auth_payload, socket) do
    %{"token" => token} = auth_payload

    with {:ok, %{pid: pid, ref: ref}} <- Static.verify_token(socket.endpoint, token),
         {:ok, config} <- Channel.register_upload(pid, ref),
         %{max_file_size: max_file_size, chunk_timeout: chunk_timeout} = config,
         {:ok, path} <- Plug.Upload.random_file("live_view_upload"),
         {:ok, handle} <- File.open(path, [:binary, :write]) do
      Process.monitor(pid)

      socket = assign(socket, %{
        path: path,
        handle: handle,
        live_view_pid: pid,
        max_file_size: max_file_size,
        chunk_timeout: chunk_timeout,
        chunk_timer: nil,
        uploaded_size: 0
      })

      {:ok, socket}
    else
      {:error, :limit_exceeded} -> {:error, %{reason: :limit_exceeded}}
      _ -> {:error, %{reason: "invalid_token"}}
    end
  end

  @impl true
  def handle_in("event", {:frame, payload}, socket) do
    %{uploaded_size: uploaded_size, max_file_size: max_file_size} = socket.assigns
    socket = reschedule_chunk_timer(socket)

    if byte_size(payload) + uploaded_size <= max_file_size do
      IO.binwrite(socket.assigns.handle, payload)
      socket = assign(socket, :uploaded_size, socket.assigns.uploaded_size + byte_size(payload))
      {:reply, :ok, socket}
    else
      reply = %{reason: "file_size_limit_exceeded", limit: max_file_size}
      {:stop, {:shutdown, :closed}, {:error, reply}, socket}
    end
  end

  @impl true
  def handle_call({:get_file, _ref}, _reply, socket) do
    File.close(socket.assigns.handle)
    {:reply, {:ok, socket.assigns.path}, socket}
  end

  @impl true
  def handle_cast(:stop, socket) do
    {:stop, :normal, socket}
  end

  @impl true
  def handle_info(
        {:DOWN, _, _, live_view_pid, reason},
        %{assigns: %{live_view_pid: live_view_pid}} = socket
      ) do
    reason = if reason == :normal, do: {:shutdown, :closed}, else: reason
    {:stop, reason, socket}
  end

  def handle_info(:chunk_timeout, socket) do
    {:stop, {:shutdown, :closed}, socket}
  end

  defp reschedule_chunk_timer(socket) do
    timer = socket.assigns.chunk_timer
    if timer, do: Process.cancel_timer(timer)
    new_timer = Process.send_after(self(), :chunk_timeout, socket.assigns.chunk_timeout)
    assign(socket, :chunk_timer, new_timer)
  end
end
