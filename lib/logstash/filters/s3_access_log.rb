# encoding: utf-8

#
# This filter will convert  Amazon S3 Server Access Log format to
# Apache Combined Log Format (CLF).
#

require "logstash/filters/base"
require "logstash/namespace"

#
# This filter will convert  Amazon S3 Server Access Log format to
# Apache Combined Log Format (CLF).
#
# Amazon S3 Server Access Log Format is documented at:
#   http://docs.aws.amazon.com/AmazonS3/latest/dev/LogFormat.html
#
# Apache Combined Log Format is documented at:
#   https://httpd.apache.org/docs/trunk/logs.html#combined
#
# The config should look like this:
#
#     filter {
#       s3_access_log {
#         copy_operation => "drop"  # "drop" or "convert" ("convert" the default))
#       }
#     }
#
# The 'copy_operation' option controls how Amazon Additional Logging for Copy Operations
# (REST.COPY.OBJECT_GET) is handled.
# See: http://docs.aws.amazon.com/AmazonS3/latest/dev/LogFormat.html#AdditionalLoggingforCopyOperations
#
# An empty request_uri with REST.COPY_OBJECT_GET operations is
# replaced with a request_uri 'POST /<key>' with referrer "REST.COPY.OBJECT_GET"
#
class LogStash::Filters::S3AccessLog < LogStash::Filters::Base

  # convert the format as specified in http://docs.aws.amazon.com/AmazonS3/latest/dev/LogFormat.html
  #
  # 1 Bucket Owner
  #   The canonical user id of the owner of the source bucket.
  # 2 Bucket
  #   The name of the bucket that the request was processed against. If the system receives a malformed request and cannot determine the bucket, the request will not appear in any server access log.
  # 3 Time
  #   The time at which the request was received. The format, using strftime() terminology, is [%d/%b/%Y:%H:%M:%S %z]
  # 4 Remote IP
  #   The apparent Internet address of the requester. Intermediate proxies and firewalls might obscure the actual address of the machine making the request.
  # 5 Requester
  #   The canonical user id of the requester, or the string "Anonymous" for unauthenticated requests. This identifier is the same one used for access control purposes.
  # 6 Request ID
  #   The request ID is a string generated by Amazon S3 to uniquely identify each request.
  # 7 Operation
  #   Either SOAP.operation, REST.HTTP_method.resource_type or WEBSITE.HTTP_method.resource_type
  # 8 Key
  #   The "key" part of the request, URL encoded, or "-" if the operation does not take a key parameter.
  # 9 Request-URI
  #   The Request-URI part of the HTTP request message.
  # 10 HTTP status
  #   The numeric HTTP status code of the response.
  # 11 Error Code
  #   The Amazon S3 Error Code, or "-" if no error occurred.
  # 12 Bytes Sent
  #   The number of response bytes sent, excluding HTTP protocol overhead, or "-" if zero.
  # 13 Object Size
  #   The total size of the object in question.
  # 14 Total Time
  #   The number of milliseconds the request was in flight from the server's perspective. This value is measured from the time your request is received to the time that the last byte of the response is sent. Measurements made from the client's perspective might be longer due to network latency.
  # 15 Turn-Around Time
  #   The number of milliseconds that Amazon S3 spent processing your request. This value is measured from the time the last byte of your request was received until the time the first byte of the response was sent.
  # 16 Referrer
  #   The value of the HTTP Referrer header, if present. HTTP user-agents (e.g. browsers) typically set this header to the URL of the linking or embedding page when making a request.
  # 17 User-Agent
  #   The value of the HTTP User-Agent header.
  # 18 Version Id
  #   The version ID in the request, or "-" if the operation does not take a versionId parameter.
  class S3AccessLogLine

    # Amazon S3 Server Access Log Format is documented at:
    #   http://docs.aws.amazon.com/AmazonS3/latest/dev/LogFormat.html
    AMAZON_S3_ACCESS_LOG_FORMAT  = Regexp.new('([^ ]*) ([^ ]*) \[([^\]]*)\] ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ("[^"]*"|-) ([^ ]*|-) ([^ ]*|-) ([^ ]*|-) ([^ ]*|-) ([^ ]*|-) ([^ ]*|-) ("[^"]*"|-) ("[^"]*"|-) ([^ ]*|-)( ?.*)')

    # Parse 'GET /11625060-v901740/20140907093122_J1084854-mp4.mp4 HTTP/1.1' into %w(GET /11625060-v901740/20140907093122_J1084854-mp4.mp4 1.1)
    AMAZON_S3_REQUEST_URI_FORMAT = Regexp.new('(\b\w+\b) (\S+)(?: HTTP\/(\d+\.\d+))?')

    S3_COPY_OPERATION = 'REST.COPY.OBJECT_GET'.freeze

    APACHE_CLF_FORMAT = "%s - %s [%s] %s %s %s %s %s %d".freeze

    def initialize(event, source_field)
      @source_line = event[source_field]
      if @source_line =~ AMAZON_S3_ACCESS_LOG_FORMAT

        event['owner']              = $1
        event['bucket']             = $2
        event['timestamp']          = $3
        event['remote_ip']          = $4
        event['requester']          = $5
        event['request_id']         = $6
        event['operation']          = $7
        event['key']                = '-' == $8 ? nil : $8 # remove empty
        event['request_uri']        = $9
        event['http_status']        = $10
        event['error_code']         = '-' == $11 ? nil : $11 # remove empty
        event['bytes']              = '-' == $12 ? 0   : $12 # bytes instead of bytes_sent intentional
        event['object_size']        = $13
        event['total_time_ms']      = $14
        event['turnaround_time_ms'] = $15
        event['referrer']           = $16
        event['agent']              = $17 # agent instead of user_agent intentional
        event['version_id']         = '-' == $18 ? nil : $18 # remove empty
        event['trailing_fields']    = $19.strip! rescue nil  # trailing fields as single string or nil if empty

        # disect request_uri
        if event['request_uri'] =~ AMAZON_S3_REQUEST_URI_FORMAT
          event['verb'], event['request'], event['httpversion'] = $1, $2, $3
        else
          event['rawrequest'] = event['request_uri']
        end
      else
        ArgumentError.new("Line not in Amazon S3 access log format: #{@source_line}")
      end
    end

    #
    # Handle Additional Logging for Copy Operations (REST.COPY.OBJECT_GET)
    # See: http://docs.aws.amazon.com/AmazonS3/latest/dev/LogFormat.html#AdditionalLoggingforCopyOperations
    #
    # An empty request_uri with REST.COPY_OBJECT_GET operations is
    # replaced with a request_uri 'POST /<key>' with referrer "REST.COPY.OBJECT_GET"
    #
    def convert_copy_operation!(event)
      raise ArgumentError.new("Not a #{S3_COPY_OPERATION}: #{@source_line}") unless is_copy_operation?(event)
      event['referrer']    = %("#{event['operation']}")
      event['agent']       = '"-"'
      event['request_uri'] = %("POST /#{event['key']} HTTP/1.1") # output as POST
      event['bytes']       = '0'
    end

    def is_copy_operation?(event)
      '-' == event['request_uri'] && S3_COPY_OPERATION == event['operation']
    end

    #
    # 206 Partial Content requests can have excessive value for bytes_sent because S3 registers the
    # bytes pushed onto the network.
    # This method recalculates the bytes_sent to estimate the bytes received by the client device
    # based on an assumed bitrate of 24 kbit/sec.
    #
    # Assume 128 Kbytes buffer is ingested and total_time_ms
    #
    def recalculate_partial_content!(event, max_kbitrate)
      if event['key'] =~ /\.mp3$/
        if 206 == event['http_status'].to_i && ((event['bytes'].to_i*8)/event['total_time_ms'].to_i > 2000)
          event['bytes'] = [ 128 * 1024 + ((max_kbitrate/8000.0).round) * event['total_time_ms'].to_i, event['bytes'].to_i ].min # 128 K buffer + 3 bytes/msec = 3 kbytes/sec = 24 kbit/sec
          event.tag RECALCULATED_TAG
        end
      end
    end

    # Apache Combined Log Format is documented at:
    #   https://httpd.apache.org/docs/trunk/logs.html#combined
    def to_apache_clf(event)
      APACHE_CLF_FORMAT % [ event['remote_ip'],   requester(event), event['timestamp'], event['request_uri'],
                            event['http_status'], event['bytes'],   event['referrer'],  event['agent'], duration(event) ]
    end

    private

    # shorten requester to max 10 characters
    def requester(event)
      event['requester'][0..9]
    end

    def duration(event)
      (event['total_time_ms'].to_i / 1000.0).round
    end

  end

  config_name "s3_access_log"
  milestone 1

  # The field to convert to JSON.
  config :source, :validate => :string

  # The field to write the JSON into. If not specified, the source
  # field will be overwritten.
  config :target, :validate => :string

  # Config option to control how to handle REST.COPY.OBJECT_GET lines.
  # Either drop or convert to POST requests.
  # See: http://docs.aws.amazon.com/AmazonS3/latest/dev/LogFormat.html#AdditionalLoggingforCopyOperations
  config :copy_operation, :validate => [ 'convert', 'drop' ], :default => 'convert'

  # Config option to control whether to recalculate 206 Partial Content requests to
  # calculate reasonable byte counts. Don't pass cost of buffering at S3 to customers.
  config :recalculate_partial_content, :validate => :boolean, :default => false

  config :max_kbitrate, :validate => :number, :default => 24000

  PARSE_FAILURE_TAG = "_s3parsefailure".freeze
  RECALCULATED_TAG = "bytes_recalculated".freeze

  public
  def register
    @source ||= 'message'
    @target ||= 'message'
  end # def register

  public
  def filter(event)
    return unless filter?(event)

    @logger.debug("Running S3 Server Access Log filter", :event => event)

    line = S3AccessLogLine.new(event, @source)

    if line.is_copy_operation?(event)
      case @copy_operation
      when 'drop'
        event.cancel
        return
      when 'convert'
        line.convert_copy_operation!(event)
      else
        raise ArgumentError.new("Invalid copy operation: #{@copy_operation}")
      end
    end

    line.recalculate_partial_content!(event, @max_kbitrate) if @recalculate_partial_content

    event[@target] = line.to_apache_clf(event)
    filter_matched(event)

    @logger.debug? && @logger.debug("Event after S3AccessLog filter", :event => event)

  rescue => e
    event.tag PARSE_FAILURE_TAG
    @logger.warn("Exception for S3 access log", :source => @source, :raw => event[@source].inspect, :exception => e)
  end # def filter

end # class LogStash::Filters::S3AccessLog
