module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class LitleGateway < Gateway
      ONLINE_URL = 'https://payments.litle.com/vap/communicator/online'
      #TEST_ONLINE_URL = 'https://cert.litle.com/vap/communicator/online'
      # or use an ssh tunnel to test
      TEST_ONLINE_URL = 'https://localhost:4443/vap/communicator/online'

      BATCH_URL = 'https://payments.litle.com:15000'
      #TEST_BATCH_URL = 'https://cert.litle.com:15000'
      # or use an ssh tunnel to test
      TEST_BATCH_URL = 'https://localhost:15000'

      LITLE_ONLINE_VERSION ='6.2'
      LITLE_BATCH_VERSION = '6.2'

      # The countries the gateway supports merchants from as 2 digit ISO country codes
      self.supported_countries = ['US']

      # The card types supported by the payment gateway
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]

      # The homepage URL of the gateway
      self.homepage_url = 'http://www.litle.com/'

      # The name of the gateway
      self.display_name = 'Litle'

      self.money_format = :cents

      CARD_TYPES = {
        'visa' => 'VI',
        'master' => 'MC',
        'american_express' => 'AX',
        'discover' => 'DI',
        'diners_club' => 'DC',
        'jcb' => 'JC',
      }

      # consider sme auth reversal responses as successful
      SUCCESS_CODES = ['000', '111', '306']

      RESPONSE_CODES = {
        '000' => 'Approved',
        '100' => 'Processing Network Unavailable',
        '101' => 'Issuer Unavailable',
        '102' => 'Re-submit Transaction',
        '110' => 'Insufficient Funds',
        '111' => 'Authorization amount has already been depleted',
        '120' => 'Call Issuer',
        '121' => 'Call AMEX',
        '122' => 'Call Diners Club',
        '123' => 'Call Discover',
        '124' => 'Call JBS',
        '125' => 'Call Visa/MasterCard',
        '126' => 'Call Issuer ‐ Update Cardholder Data',
        '127' => 'Exceeds Approval Amount Limit',
        '130' => 'Call Indicated Number',
        '140' => 'Update Cardholder Data',
        '191' => 'The merchant is not registered in the update program.',
        '301' => 'Invalid Account Number',
        '302' => 'Account Number Does Not Match Payment Type',
        '303' => 'Pick Up Card',
        '304' => 'Lost/Stolen Card',
        '305' => 'Expired Card',
        '306' => 'Authorization has expired; no need to reverse',
        '307' => 'Restricted Card',
        '308' => 'Restricted Card ‐ Chargeback',
        '310' => 'Invalid track data',
        '311' => 'Deposit is already referenced by a chargeback',
        '320' => 'Invalid Expiration Date',
        '321' => 'Invalid Merchant',
        '322' => 'Invalid Transaction',
        '323' => 'No such issuer',
        '324' => 'Invalid Pin',
        '325' => 'Transaction not allowed at terminal',
        '326' => 'Exceeds number of PIN entries',
        '327' => 'Cardholder transaction not permitted',
        '328' => 'Cardholder requested that recurring or installment payment be stoped',
        '330' => 'Invalid Payment Type',
        '340' => 'Invalid Amount',
        '335' => 'This method of payment does not support authorization reversals',
        '346' => 'Invalid billing descriptor prefix',
        '349' => 'Do Not Honor',
        '350' => 'Generic Decline',
        '351' => 'Decline - Request Positive ID',
        '352' => 'Decline CVV2/CID Fail',
        '353' => 'Merchant requested decline due to AVS result',
        '354' => '3-D Secure transaction not supported by merchant',
      }

      # map Litle AVS response codes to ActiveMerchant AVSResult codes
      AVS_CODES = {
        '00' => 'Y',
        '01' => 'X',
        '02' => 'D',
        '10' => 'Z',
        '11' => 'W',
        '12' => 'A',
        '13' => 'A',
        '14' => 'P',
        '20' => 'C',
        '30' => 'S',
        '31' => 'R',
        '32' => 'U',
        '33' => 'R',
        '34' => 'I',
        '40' => 'U',
      }
      
      ORDER_SOURCE_3DSAUTH      = '3dsAuthenticated'
      ORDER_SOURCE_3DSATTEMPT   = '3dsAuthenticated'
      ORDER_SOURCE_ECOMMERCE    = 'ecommerce'
      ORDER_SOURCE_INSTALLMENT  = 'installment'
      ORDER_SOURCE_MAILORDER    = 'mailorder'
      ORDER_SOURCE_RECURRING    = 'recurring'
      ORDER_SOURCE_RETAIL       = 'retail'
      ORDER_SOURCE_TELEPHONE    = 'telephone'
      
      cattr_accessor :logger
      self.logger = nil

      def initialize(options = {})
        #requires!(options, :login, :password)
        @options = options
        super
        @batch_ids = []
        unless @options[:log].nil?
          self.logger = Logger.new(@options[:log])
        end
      end

      def authorize(*args)
        if args.first.is_a?(Array)
          # batch request
          txns = args.first
          txns.empty? ? [] : commit_batch(build_batch_request(:authorization_txns => txns))
        else
          money, authorization, options = args
          commit_online('authorization', build_authorization_request(money, authorization, parse_options(options)))
        end
      end

      def capture(*args)
        if args.first.is_a?(Array)
          # batch request
          txns = args.first
          txns.empty? ? [] : commit_batch(build_batch_request(:capture_txns => txns))
        else
          money, authorization, options = args
          commit_online('capture', build_capture_request(money, authorization, parse_options(options)))
        end
      end

      def credit(*args)
        if args.first.is_a?(Array)
          # batch request
          txns = args.first
          txns.empty? ? [] :commit_batch(build_batch_request(:credit_txns => txns))
        else
          money, authorization_or_credit_card, options = args
          commit_online('credit', build_credit_request(money, authorization_or_credit_card, parse_options(options)))
        end
      end

      def purchase(*args)
        if args.first.is_a?(Array)
          txns = args.first
          txns.empty? ? [] : commit_batch(build_batch_request(:sale_txns => txns))
        else
          money, credit_card, options = args
          commit_online('sale', build_sale_request(money, credit_card, parse_options(options)))
        end
      end

      # Auth Reversal params: void(money, authorization, options)
      # Void params: void(authorization, options)
      def void(*args)
        if args.first.is_a?(Array)
          txns = args.first
          txns.empty? ? [] : commit_batch(build_batch_request(:void_txns => txns))
        elsif args.first.is_a?(Numeric) or args.first == nil
          money, authorization, options = args
          options ||= {}
          commit_online('authReversal', build_auth_reversal_request(money, authorization, parse_options(options)))
        else
          authorization, options = args
          options ||= {}
          commit_online('void', build_void_request(authorization, parse_options(options)))
        end
      end

      # sends a response to a previous batch request, identified by the Litle session ID
      # the Litle session ID is found through non-programatic means (call or Litle admin site)
      def request_for_response(session_id)
        commit_batch(build_rfr_request(session_id))
      end


    private
    
      def parse_options(opts={})
        options = {:report_group => 'online', :order_source => ORDER_SOURCE_ECOMMERCE}.merge(opts)
        options[:report_group] = 'online' unless options[:report_group]
        options
      end
    
      def expdate(credit_card)
        year  = format(credit_card.year, :two_digits)
        month = format(credit_card.month, :two_digits)
        "#{month}#{year}"
      end

      def unique_id(options, n=nil)
        if !options.nil? and options.has_key?(:txn_id)
          options[:txn_id].to_s[0..24]
        else
          if n.nil?
            "#{Time.now.to_i}"[0..24]
          else
            "#{n}#{Time.now.to_i}"[0..24]
          end
        end
      end

      def build_address(address)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.name(address[:name][0..99]) unless address[:name].blank?
        xml.addressLine1(address[:address1][0..34]) unless address[:address1].blank?
        xml.addressLine2(address[:address2][0..34]) unless address[:address2].blank?
        xml.city(address[:city][0..34]) unless address[:city].blank?
        xml.state(address[:state][0..29]) unless address[:state].blank?
        xml.zip(address[:zip][0..19]) unless address[:zip].blank?
        xml.country(address[:country][0..19]) unless address[:country].blank?
        xml.phone(address[:phone][0..19]) unless address[:phone].blank?
        xml.target!
      end

      def build_card(credit_card)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.type CARD_TYPES[credit_card.type]
        xml.number credit_card.number
        xml.expDate expdate(credit_card)
        xml.cardValidationNum credit_card.verification_value if credit_card.verification_value
        xml.target!
      end

      def build_authorization_request(money, credit_card, options)
        # get a big random id, this should be unique enough. Doesn't have to be perfect
        id = unique_id(options, options[:order_id])
        @batch_ids << id
        billing_address = options[:billing_address] || options[:address]
        order_source = options[:order_source]
        
        # TODO - add customer_id back in
        xml = Builder::XmlMarkup.new(:indent => 2)
        xml.authorization(:id => id, :reportGroup => options[:report_group], :customerId => nil) do
          xml.orderId(options[:order_id])
          xml.amount(amount(money))
          xml.orderSource(order_source)
          xml.billToAddress do
            xml << build_address(billing_address)
          end if billing_address
          xml.shipToAddres do
            xml << build_address(options[:shipping_address])
          end if options[:shipping_address]
          xml.card do
            xml << build_card(credit_card)
          end
        end
        xml.target!
      end

      def build_capture_request(money, authorization, options)
        id = unique_id(options, options[:order_id])
        @batch_ids << id
        capture_options = {:id => id, :reportGroup => options[:report_group], :customerId => nil}
        if options.key?(:partial) and options[:partial]
          capture_options[:partial] = 'true'
        end

        litle_txn_id, auth_code = authorization.split(';')

        xml = Builder::XmlMarkup.new :indent => 2
        xml.capture capture_options do
          xml.litleTxnId litle_txn_id
          xml.amount amount(money)
        end
        xml.target!
      end

      def build_credit_request(money, authorization_or_credit_card, options)
        id = unique_id(options, options[:order_id])
        @batch_ids << id
        if authorization_or_credit_card.is_a?(CreditCard)
          non_litle = true
        else
          non_litle = false
          litle_txn_id, auth_code = authorization_or_credit_card.split(';')
        end

        xml = Builder::XmlMarkup.new :indent => 2
        xml.credit :id => id, :reportGroup => options[:report_group], :customerId => nil do
          if non_litle
            order_source = options[:order_source]
            xml.orderId(options[:order_id])
            xml.amount amount(money)
            xml.orderSource(order_source)
            xml.card do
              xml << build_card(authorization_or_credit_card)
            end
          else
            xml.litleTxnId litle_txn_id
            xml.amount amount(money)
          end
        end
        xml.target!
      end

      def build_sale_request(money, credit_card, options)
        id = unique_id(options, options[:order_id])
        @batch_ids << id
        billing_address = options[:billing_address] || options[:address]
        order_source = options[:order_source]
        xml = Builder::XmlMarkup.new(:indent => 2)
        xml.sale(:id => id, :reportGroup => options[:report_group], :customerId => nil) do
          xml.orderId(options[:order_id])
          xml.amount(amount(money))
          xml.orderSource(order_source)
          xml.billToAddress do
            xml << build_address(billing_address)
          end if billing_address
          xml.shipToAddres do
            xml << build_address(options[:shipping_address])
          end if options[:shipping_address]
          xml.card do
            xml << build_card(credit_card)
          end
        end
        xml.target!
      end

      def build_void_request(authorization, options)
        litle_txn_id, auth_code = authorization.split(';')
        id = unique_id(options, litle_txn_id)
        @batch_ids << id
        xml = Builder::XmlMarkup.new :indent => 2
        xml.void(:id => id, :reportGroup => options[:report_group], :customerId => nil) do
          xml.litleTxnId litle_txn_id
        end
        xml.target!
      end

      def build_auth_reversal_request(money, authorization, options)
        litle_txn_id, auth_code = authorization.split(';')
        id = unique_id(options, litle_txn_id)
        @batch_ids << id

        xml = Builder::XmlMarkup.new :indent => 2
        xml.authReversal(:id => id, :reportGroup => options[:report_group], :customerId => nil) do
          xml.litleTxnId litle_txn_id
          xml.amount amount(money) if money
        end
        xml.target!
      end

      def build_rfr_request(session_id)
        total = 0
        id = unique_id(@options, session_id)
        xml = Builder::XmlMarkup.new :indent => 2
        xml.instruct! :xml
        xml.litleRequest(:version=>LITLE_BATCH_VERSION, :xmlns=>"http://www.litle.com/schema",
            :id => unique_id(@options), :numBatchRequests => total ) do
          xml.authentication do
            xml.user(@options[:login])
            xml.password(@options[:password])
          end
          xml.RFRRequest do
            xml.litleSessionId(session_id)
          end
        end
        xml.target!
      end

      def build_batch_request(*args)
        # voids cannot be batched, so we assume that all batched void_txns are authReversals
        opts = {
          :authorization_txns => [],
          :capture_txns => [],
          :credit_txns => [],
          :sale_txns => [],
          :void_txns => []
        }
        opts.update(args.first) if args.first.is_a?(Hash)
        @batch_ids = []

        total = 1
        xml = Builder::XmlMarkup.new :indent => 2
        xml.instruct! :xml
        xml.litleRequest(:version=>LITLE_BATCH_VERSION, :xmlns=>"http://www.litle.com/schema",
            :id => unique_id(@options), :numBatchRequests => total ) do
          xml.authentication do
            xml.user(@options[:login])
            xml.password(@options[:password])
          end
          xml.batchRequest(:id => unique_id(@options),
              :numAuths => opts[:authorization_txns].size,
              :authAmount => opts[:authorization_txns].inject(0) {|sum, a| sum + a.first},
              :numCaptures => opts[:capture_txns].size,
              :captureAmount => opts[:capture_txns].inject(0) {|sum, a| sum + a.first},
              :numCredits => opts[:credit_txns].size,
              :creditAmount => opts[:credit_txns].inject(0) {|sum, a| sum + a.first},
              :numSales => opts[:sale_txns].size,
              :saleAmount => opts[:sale_txns].inject(0) {|sum, a| sum + a.first},
              :numAuthReversals => opts[:void_txns].size,
              :authReversalAmount => opts[:void_txns].inject(0) {|sum, a| a.first.nil? ? sum + 0 : sum + a.first},
              :merchantId => @options[:merchant_key]) do
            opts[:authorization_txns].each do |money, credit_card, options|
              xml << build_authorization_request(money, credit_card, parse_options(options))
            end
            opts[:capture_txns].each do |money, authorization, options|
              xml << build_capture_request(money, authorization, parse_options(options))
            end
            opts[:credit_txns].each do |money, authorization_or_credit_card, options|
              xml << build_credit_request(money, authorization_or_credit_card, parse_options(options))
            end
            opts[:sale_txns].each do |money, credit_card, options|
              xml << build_sale_request(money, credit_card, parse_options(options))
            end
            opts[:void_txns].each do |args|
              # cannot batch void requests, only batch authReversals
              if args.first.is_a?(Numeric) or args.first == nil
                money, authorization, options = args
                xml << build_auth_reversal_request(money, authorization, parse_options(options))
              end
            end
          end
        end
        xml.target!
      end

      def build_online_request(body)
        xml = Builder::XmlMarkup.new(:indent => 2)
        xml.instruct! :xml
        xml.litleOnlineRequest(:version=>LITLE_ONLINE_VERSION, :merchantId=> @options[:merchant_key], :xmlns=>"http://www.litle.com/schema/online" ) do
          xml.authentication do
            xml.user(@options[:login])
            xml.password(@options[:password])
          end
          xml << body
        end
        xml.target!
      end

      def parse_element(response, node)
        if node.has_elements?
          node.elements.each{|e| parse_element(response, e) }
        else
          response[node.name.underscore.to_sym] = node.text.strip
        end
      end

      def parse_online(action, xml)
        response = {}
        response[:litle_batch_id] = nil
        error_messages = []
        error_codes = []
        log ">>> RESPONSE ONLINE: #{xml}"
        xml = REXML::Document.new(xml)
        if root = REXML::XPath.first(xml, "litleOnlineResponse") and root.attributes['response'] == '0'
          root.elements.each do |node|
            # put the txn type into the response so it can be verified
            if node.name =~ /^(.+)Response$/
              response[:litle_txn_type] = $1
              response[:txn_id] = node.attributes['id']
              response[:report_group] = node.attributes['reportGroup']
            end
            parse_element(response, node)
          end
          # response[:error_codes] = error_codes.uniq.join(",") unless error_codes.empty?
        else
          response[:message] = "#{root.attributes['message']}"
        end
        response
      end

      def parse_batch(xml)
        # TODO - Match up response with corresponding request and fill in the order_id,
        # or can we assume the response is in the same order as the send?  really?
        response = {}
        unsorted_responses = {}
        error_messages = []
        error_codes = []
        log ">>> RESPONSE BATCH: #{xml}"
        xml = REXML::Document.new(xml)
        if root = REXML::XPath.first(xml, "litleResponse") and root.attributes['response'] == '0'
          root.elements.each do |node|
            if node.name == "batchResponse"
              litle_batch_id = node.attributes['litleBatchId']
              node.elements.each do |node|
                response = {}
                response[:litle_batch_id] = litle_batch_id
                # put the txn type into the response so it can be verified
                if node.name =~ /^(.+)Response$/
                  response[:litle_txn_type] = $1
                  response[:txn_id] = node.attributes['id']
                  response[:report_group] = node.attributes['reportGroup']
                end
                parse_element(response, node)
                unsorted_responses[node.attributes['id'].to_s] = response
              end
            else
              response[:message] = "#{root.attributes['message']}"
            end
          end
          # response[:error_codes] = error_codes.uniq.join(",") unless error_codes.empty?
        else
          response[:message] = "#{root.attributes['message']}"
        end
        if unsorted_responses.empty?
          response
        else
          if @batch_ids.empty?
            unsorted_responses.map { |id, r| r }
          else
            @batch_ids.map {|id| unsorted_responses[id.to_s]}
          end
        end
      end

      def online_url
        test? ? TEST_ONLINE_URL : ONLINE_URL
      end

      def batch_url
        test? ? TEST_BATCH_URL : BATCH_URL
      end

      def create_response(raw_response)
        Response.new(successful?(raw_response), message_from(raw_response), raw_response,
            :test => test?,
            :authorization => successful?(raw_response) ? authorization_from(raw_response) : nil,
            :avs_result => { :code => AVS_CODES[raw_response[:avs_result]] },
            :cvv_result => raw_response[:card_validation_result]
        )
      end

      def commit_batch(request)
        log ">>> REQUEST BATCH: #{request}"
        raw_responses = parse_batch(ssl_post(batch_url, request))
        if raw_responses.is_a?(Array)
          responses = []
          raw_responses.each do |raw_response|
            responses.push(create_response(raw_response))
          end
          responses
        else
          # must be an error
          create_response(raw_responses)
        end
      end

      def commit_online(action, request)
        log ">>> REQUEST ONLINE: #{build_online_request(request)}"
        raw_response = parse_online(action, ssl_post(online_url, build_online_request(request)))
        create_response(raw_response)
      end

      def successful?(raw_response)
        SUCCESS_CODES.include? raw_response[:response]
      end

      def message_from(raw_response)
        raw_response[:message]
      end

      def authorization_from(raw_response)
        "#{raw_response[:litle_txn_id]};#{raw_response[:auth_code]}"
      end

      def log(message)
        self.logger.info(sanitize(message)) unless self.logger.nil?
      end

      FILTER_FIELD_LOGGING = ['password']

      def sanitize(string)
        FILTER_FIELD_LOGGING.each do |field|
          string = string.gsub(/<#{field}>(.*)<\/#{field}>/, "<#{field}></#{field}>")
        end

        # replace number
        string = string.gsub(/<number>(.*)(\d{4})<\/number>/) { '<number>' + 'x' * $1.size + $2 + '</number>' }
        return string
      end
    end
  end
end

