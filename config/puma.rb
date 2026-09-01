# frozen_string_literal: true

port = Integer(ENV.fetch("PORT", "4001"))
bind "tcp://[::]:#{port}"
