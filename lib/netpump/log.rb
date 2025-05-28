$log = $>
$log.sync = true

def log(msg, **context)
  line = "%-35s" % msg
  context.each do |k, v|
    case v
    when Exception
      line << " #{k}=#{v.message.inspect}"
      line << " backtrace=#{v.backtrace}" if !$VERBOSE.nil? && v.backtrace
    when true
      line << " #{k}"
    when false, nil, ""
      # skip
    else
      v = v.to_s
      v = v.inspect if v.include?(" ")
      line << " #{k}=#{v}"
    end
  end
  $log.puts(line)
end
