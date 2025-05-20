# frozen_string_literal: true

require "pathname"

module StaticFiles
  def receive_data(data)
    file = asset_file(data) or return super
    send_data "HTTP/1.1 200 OK\r\n\r\n"
    # win: send/stream_file_data do not work on windows
    send_data file.read
    close_connection_after_writing
  end

  DIR = Pathname(__dir__).parent.join("public").freeze
  private_constant :DIR

  INDEX = "index.html"
  private_constant :INDEX

  private

  def asset_file(data)
    match = data.match(/^(HEAD|GET) \/(?<path>[\w.-]*)?(?:\?\S*)? HTTP/) or return
    path = match[:path]
    path = INDEX if path.empty?
    file = DIR.join(path)
    file if file.file? && file.readable?
  end
end
