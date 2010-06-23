require 'test_helper'

class LitleTest < Test::Unit::TestCase
  def setup
    @gateway = LitleGateway.new(
                 :login => 'login',
                 :password => 'password'
               )
    @mock_log = MockStream.new
    @gateway.logger = Logger.new(@mock_log)
    @credit_card = credit_card
    @amount = 100

    @options = {
      :order_id => '1',
      :billing_address => address,
      :description => 'Authorize test'
    }
  end

  def test_successful_authorize_capture_request
    @gateway.expects(:ssl_post).returns(successful_authorize_response)
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_instance_of Response, response
    assert_success response

    assert_equal '27200086782401;55555', response.authorization
    assert_equal('U', response.avs_result['code'])
    assert_equal('M', response.cvv_result['code'])
    assert_equal('000', response.params['response'])
    assert_equal(LitleGateway::RESPONSE_CODES[response.params['response']], response.message)
    assert_equal('55555', response.params['auth_code'])
    assert_equal('authorization', response.params['litle_txn_type'])
    assert response.test?

    @gateway.expects(:ssl_post).returns(successful_capture_response)
    assert response = @gateway.capture(@amount, response.authorization, @options)
    assert_instance_of Response, response
    assert_success response
    assert_equal '27200086782401;', response.authorization
    assert_equal('000', response.params['response'])
    assert_equal('capture', response.params['litle_txn_type'])

    @gateway.expects(:ssl_post).returns(successful_credit_response)
    assert response = @gateway.credit(@amount, response.authorization, @options)
    assert_instance_of Response, response
    assert_success response
    assert_equal '27200086782401;', response.authorization
    assert_equal('000', response.params['response'])
    assert_equal('credit', response.params['litle_txn_type'])
  end

  def test_failed_authorize_request
    @gateway.expects(:ssl_post).returns(failed_authorize_response)

    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_failure response
    assert_equal('authorization', response.params['litle_txn_type'])
    assert_equal("12399106877432", response.params['txn_id'])
    assert response.test?
  end

  def test_successful_purchase_request
    @gateway.expects(:ssl_post).returns(successful_purchase_response)

    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal('sale', response.params['litle_txn_type'])
    assert response.test?
  end

  def test_successful_void_request
    @gateway.expects(:ssl_post).returns(successful_void_response)
    assert response = @gateway.void("84568456;123456", @options)
    assert_equal('void', response.params['litle_txn_type'])
    assert_success response
  end

  def test_successful_auth_reversal_request
    @gateway.expects(:ssl_post).returns(successful_auth_reversal_response)
    assert response = @gateway.void(1000, "84568456;123456", @options)
    assert_success response
    assert_equal('authReversal', response.params['litle_txn_type'])
  end

  def test_successful_batch_authorize_request
    @gateway.expects(:ssl_post).returns(successful_batch_response)

    options_1 = {
      :order_id => '1',
      :txn_id => '1',
      :billing_address => address,
      :description => 'Authorize test'
    }

    options_2 = {
      :order_id => '2',
      :txn_id => '2',
      :billing_address => address,
      :description => 'Authorize test'
    }

    assert response = @gateway.authorize([[@amount, @credit_card, options_1],
        [@amount, @credit_card, options_2]])
    assert_instance_of Array, response
    assert_equal(2, response.size)
    r = response[0]
    assert_success r
    assert_equal("84568457;123456", r.authorization)
    assert_equal('000', r.params['response'])
    assert_equal('Y', r.avs_result['code'])
    assert_equal('authorization', r.params['litle_txn_type'])
    assert_equal '4455667788', r.params['litle_batch_id']
    assert_equal("1", r.params['txn_id'])

    r = response[1]
    assert_success r
    assert_equal("84568456;123456", r.authorization)
    assert_equal('000', r.params['response'])
    assert_equal('Y', r.avs_result['code'])
    assert_equal('authorization', r.params['litle_txn_type'])
    assert_equal '4455667788', r.params['litle_batch_id']
    assert_equal("2", r.params['txn_id'])
  end

  def test_request_for_response
    @gateway.expects(:ssl_post).returns(successful_batch_response)
    assert responses = @gateway.request_for_response('123456')
    assert_instance_of Array, responses
    assert_equal(2, responses.size)
    responses.each do |r|
      assert_success r
    end
  end

  def test_failed_online_response
    @gateway.expects(:ssl_post).returns(failed_online_response)

    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_failure response
    assert response.test?
    assert_equal 'System Error - Call Litle & Co.', response.message
  end

  def test_failed_batch_response
    @gateway.expects(:ssl_post).returns(failed_batch_response)

    assert response = @gateway.authorize([[@amount, @credit_card, @options], [@amount, @credit_card, @options]])
    assert_failure response
    assert response.test?
    assert_equal("Error validating xml data against the schema on line 18 the value is not a member of the enumeration.", response.message)
  end

  def test_empty_batch_request
    assert response = @gateway.authorize([])
    assert response.empty?
  end

  def test_batch_response_order
    @gateway.expects(:ssl_post).returns(successful_batch_response)

    options_1 = {
      :order_id => '1',
      :txn_id => '1',
      :billing_address => address,
      :description => 'Authorize test'
    }
    authorize_txn_1 = [@amount, @credit_card, options_1]

    options_2 = {
      :order_id => '2',
      :txn_id => '2',
      :billing_address => address,
      :description => 'Authorize test'
    }
    authorize_txn_2 = [@amount, @credit_card, options_2]

    assert responses = @gateway.authorize([authorize_txn_1, authorize_txn_2])
    responses.each do |response|
      assert_success response
    end
    assert_equal('1', responses.first.params['order_id'])
    assert_equal('2', responses.last.params['order_id'])
  end

  def test_sanitize
    result_string = @gateway.send(:sanitize, authorization_request)
    assert_not_nil(result_string =~ /<number>xxxxxxxxxxxx4242<\/number>/)
    assert_not_nil(result_string =~ /<password><\/password>/)
  end

  def test_log
    @gateway.send(:log, authorization_request)
    assert_not_nil(@mock_log.contents =~ /<number>xxxxxxxxxxxx4242<\/number>/)
    assert_not_nil(@mock_log.contents =~ /<password><\/password>/)
  end

  private

  def successful_authorize_response
    '<litleOnlineResponse version="1.0"
        xmlns="http://www.litle.com/schema/online" response="0" message="Valid Format">
        <authorizationResponse id="12399107165113" reportGroup="online" customerId="">
            <litleTxnId>27200086782401</litleTxnId>
            <orderId>5</orderId>
            <response>000</response>
            <responseTime>2009-04-16T19:38:37</responseTime>
            <postDate>2009-04-16</postDate>
            <message>Approved</message>
            <authCode>55555</authCode>
            <fraudResult>
                <avsResult>32</avsResult>
                <cardValidationResult>M</cardValidationResult>
            </fraudResult>
        </authorizationResponse>
    </litleOnlineResponse>'
  end

  def successful_capture_response
    '<litleOnlineResponse version="1.0"
        xmlns="http://www.litle.com/schema/online" response="0" message="Valid Format">
        <captureResponse reportGroup="online" id="12399107175684" customerId="">
            <litleTxnId>27200086782401</litleTxnId>
            <response>000</response>
            <responseTime>2009-04-16T19:38:39</responseTime>
            <postDate>2009-04-16</postDate>
            <message>Approved</message>
        </captureResponse>
    </litleOnlineResponse>'

  end

  def successful_credit_response
    '<litleOnlineResponse version="1.0"
        xmlns="http://www.litle.com/schema/online" response="0" message="Valid Format">
        <creditResponse reportGroup="online" id="12399107205663" customerId="">
            <litleTxnId>27200086782401</litleTxnId>
            <response>000</response>
            <responseTime>2009-04-16T19:38:41</responseTime>
            <postDate>2009-04-16</postDate>
            <message>Approved</message>
        </creditResponse>
    </litleOnlineResponse>'
  end

  def successful_purchase_response
    '<litleOnlineResponse version="1.0"
        xmlns="http://www.litle.com/schema/online" response="0" message="Valid Format">
        <saleResponse reportGroup="online" id="12402165271217" customerId="">
            <litleTxnId>27200093832108</litleTxnId>
            <orderId>1</orderId>
            <response>000</response>
            <responseTime>2009-04-20T08:35:29</responseTime>
            <postDate>2009-04-20</postDate>
            <message>Approved</message>
            <authCode>11111</authCode>
            <fraudResult>
                <avsResult>01</avsResult>
                <cardValidationResult>M</cardValidationResult>
            </fraudResult>
        </saleResponse>
    </litleOnlineResponse>'
  end

  def successful_batch_response
    '<litleResponse version="1.1"
          xmlns="http://www.litle.com/schema"
          id="123" response="0" message="Valid Format"
          litleSessionId="987654321">
      <batchResponse id="01234567" litleBatchId="4455667788" merchantId="100">
        <authorizationResponse id="2" reportGroup="RG27">
          <litleTxnId>84568456</litleTxnId>
          <orderId>2</orderId>
          <response>000</response>
          <responseTime>2005-09-01T10:24:31</responseTime>
          <message>Approved</message>
          <authCode>123456</authCode>
          <fraudResult>
            <avsResult>00</avsResult>
          </fraudResult>
        </authorizationResponse>
        <authorizationResponse id="1" reportGroup="RG12">
          <litleTxnId>84568457</litleTxnId>
          <orderId>1</orderId>
          <response>000</response>
          <responseTime>2005-09-01T10:24:31</responseTime>
          <message>Approved</message>
          <authCode>123456</authCode>
          <fraudResult>
            <avsResult>00</avsResult>
            <authenticationResult>2</authenticationResult>
          </fraudResult>
        </authorizationResponse>
      </batchResponse>
    </litleResponse>'
  end

  def successful_void_response
    '<litleOnlineResponse version="4.1"
        xmlns="http://www.litle.com/schema/online" response="0"
        message="Valid Format">
        <voidResponse id="1" reportGroup="Void Division">
            <litleTxnId>1100026202</litleTxnId>
            <response>000</response>
            <responseTime>2005-08-16T19:43:38</responseTime>
            <postDate>2005-08-16</postDate>
            <message>Approved</message>
        </voidResponse>
    </litleOnlineResponse>'
  end

  def successful_auth_reversal_response
    '<litleOnlineResponse version="4.1"
        xmlns="http://www.litle.com/schema/online" response="0"
        message="Valid Format">
      <authReversalResponse reportGroup="UI Report Group">
        <litleTxnId>1100026202</litleTxnId>
        <orderId>123</orderId>
        <response>000</response>
        <responseTime>2005-08-16T19:43:38</responseTime>
        <message>Approved</message>
      </authReversalResponse>
    </litleOnlineResponse>'
  end

  def failed_authorize_response
    '<litleOnlineResponse version="1.0"
        xmlns="http://www.litle.com/schema/online" response="0" message="Valid Format">
        <authorizationResponse id="12399106877432" reportGroup="online" customerId="">
            <litleTxnId>27200086782401</litleTxnId>
            <orderId>7</orderId>
            <response>301</response>
            <responseTime>2009-04-16T19:38:08</responseTime>
            <postDate>2009-04-16</postDate>
            <message>Invalid Account Number</message>
            <fraudResult>
                <avsResult>34</avsResult>
                <cardValidationResult>N</cardValidationResult>
            </fraudResult>
        </authorizationResponse>
    </litleOnlineResponse>'
  end

  def failed_batch_response
    '<litleResponse version="3.0" xmlns="http://www.litle.com/schema" response="1" message="Error validating xml data against the schema on line 18 the value is not a member of the enumeration." litleSessionId="27512406201">
    </litleResponse>'
  end

  def failed_online_response
    '<litleOnlineResponse version="1.0" xmlns="http://www.litle.com/schema/online" response="1" message="System Error - Call Litle &amp; Co.">
    </litleOnlineResponse>'
  end

  def authorization_request
    '<litleOnlineRequest xmlns=\"http://www.litle.com/schema/online\" version=\"6.2\" merchantId=\"\">
      <authentication>
        <user>login</user>
        <password>password</password>
      </authentication>
      <authorization reportGroup=\"online\" customerId=\"\" id=\"11268178293\">
        <orderId>1</orderId>
        <amount>100</amount>
        <orderSource>ecommerce</orderSource>
        <billToAddress>
          <name>Jim Smith</name>
          <addressLine1>1234 My Street</addressLine1>
          <addressLine2>Apt 1</addressLine2>
          <city>Ottawa</city>
          <state>ON</state>
          <zip>K1C2N6</zip>
          <country>CA</country>
          <phone>(555)555-5555</phone>
        </billToAddress>
        <card>
          <type>VI</type>
          <number>4242424242424242</number>
          <expDate>0911</expDate>
          <cardValidationNum>123</cardValidationNum>
        </card>
      </authorization>
    </litleOnlineRequest>'
  end
end


class MockStream < Object
  attr_accessor :contents

  def initialize
    self.contents = ''
  end

  def write(contents)
    self.contents += contents
  end

  def close
    return true
  end
end