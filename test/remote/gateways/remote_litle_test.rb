require 'test_helper'

class RemoteLitleTest < Test::Unit::TestCase

  LITLE_AUTHORIZATION_TESTS = [
    { :type => 'visa', :success => true, :response_code => '000', :auth_code => '11111',
        :avs_result_code => 'X', :cvv_result_code => 'M' },
    { :type => 'master', :success => true, :response_code => '000', :auth_code => '22222',
        :avs_result_code => 'Z', :cvv_result_code => 'M' },
    { :type => 'discover', :success => true, :response_code => '000', :auth_code => '33333',
        :avs_result_code => 'Z', :cvv_result_code => 'M', :capture_credit => true },
    { :type => 'american_express', :success => true, :response_code => '000', :auth_code => '44444',
        :avs_result_code => 'A', :cvv_result_code => 'N' },
    { :type => 'visa', :success => true, :response_code => '000', :auth_code => '55555',
        :avs_result_code => 'U', :cvv_result_code => 'M' },
    { :type => 'visa', :success => false, :response_code => '110', :auth_code => nil,
        :avs_result_code => 'I', :cvv_result_code => 'P' },
    { :type => 'master', :success => false, :response_code => '301', :auth_code => nil,
        :avs_result_code => 'I', :cvv_result_code => 'N' },
    { :type => 'discover', :success => false, :response_code => '120', :auth_code => nil,
        :avs_result_code => 'I', :cvv_result_code => 'P' },
    { :type => 'american_express', :success => false, :response_code => '303', :auth_code => nil,
        :avs_result_code => 'I', :cvv_result_code => nil },
  ]

  LITLE_AUTH_REVERSAL_TESTS = [
    { :capture_amount => 5005, :reversal_amount => nil, :success => true, :response_code => '111' },
    { :capture_amount => 0, :reversal_amount => nil, :success => true, :response_code => '000' },
    { :capture_amount => 0, :reversal_amount => nil, :success => true, :response_code => '000' },
    { :capture_amount => 20020, :reversal_amount => 20020, :success => false, :response_code => '335' },
  ]

  # define individual methods so it's easier to read test failure output
  (1..9).each do |n|
    send :define_method, "test_transaction_#{n}" do
      run_authorize_capture_credit_void_test n
    end
  end

  # cannot batch voids
  (1..9).each do |n|
    send :define_method, "test_purchase_void_#{n}" do
      run_purchase_void_test n
    end
  end

  (1..4).each do |n|
    send :define_method, "test_auth_reversal_#{n}" do
      run_authorize_auth_reversal_test n
    end
  end

  def credit_card(options = {})
    CreditCard.new(options)
  end

  def setup
    Base.gateway_mode = :test
    Gateway.ssl_strict = false
    @gateway = LitleGateway.new(fixtures(:litle))
    # uncomment to dump transactions to STDOUT
    @gateway.logger = Logger.new(STDOUT)
  end

  def test_failed_capture
    # try to capture non-existant auth
    assert response = @gateway.capture(10010, '123;123', {})
    assert_failure response
    assert_equal('360', response.params['response'])
    assert response.params['litle_txn_type'] == 'capture'
  end

  def test_batch_transaction
    authorization_txns = Array.new(9) {|n| setup_authorize n+1}
    assert responses = @gateway.authorize(authorization_txns)
    assert responses.all? { |r| r.params['litle_txn_type'] == 'authorization' }
    assert_equal(9, responses.size)
    authorizations = {}
    (1..9).each do |n|
      verify_authorize_response(n, responses[n-1])
      if responses[n-1].success?
        authorizations[n-1] = responses[n-1].authorization
      end
    end

    # test capture
    capture_txns = authorizations.map {|k, v| [authorization_txns[k].first, v, authorization_txns[k].last]}
    assert responses = @gateway.capture(capture_txns)
    assert responses.all? { |r| r.params['litle_txn_type'] == 'capture' }
    assert_equal(5, responses.size)
    assert responses.all? {| r| r.success? }

    # test credit
    authorizations.keys.each {|k| authorizations[k] = responses.shift.authorization}
    credit_txns = authorizations.map {|k, v| [authorization_txns[k].first, v, authorization_txns[k].last]}
    assert responses = @gateway.credit(credit_txns)
    assert responses.all? { |r| r.params['litle_txn_type'] == 'credit' }
    assert_equal(5, responses.size)
    assert responses.all? { |r| r.success? }
  end

  # def test_large_batch_transaction
  #   # use a gateway without logging
  #   gateway = LitleGateway.new(fixtures(:litle))
  #   gateway.logger = nil
  #
  #   authorization_txns = []
  #   (1..1000).each do |m|
  #     (1..9).each do |n|
  #       authorization_txns << setup_authorize(n)
  #     end
  #   end
  #   assert responses = gateway.authorize(authorization_txns)
  #   assert_equal(9000, responses.size)
  # end

  def test_batch_purchase
    purchase_txns = (1..9).map {|n| setup_authorize n}
    responses = @gateway.purchase(purchase_txns)
    assert responses.all? { |r| r.params['litle_txn_type'] == 'sale' }
    assert_equal(9, responses.size)
    authorizations = []
    (1..9).each { |n| verify_authorize_response(n, responses[n-1]) }
  end

  def test_batch_authorize_auth_reversal
    authorization_txns = Array.new(9) {|n| setup_authorize n+1}
    assert responses = @gateway.authorize(authorization_txns)
    assert responses.all? { |r| r.params['litle_txn_type'] == 'authorization' }
    assert_equal(9, responses.size)
    authorizations = {}
    (1..9).each do |n|
      verify_authorize_response(n, responses[n-1])
      if responses[n-1].success?
        authorizations[n-1] = responses[n-1].authorization
      end
    end

    # test auth reversal
    capture_txns = []
    LITLE_AUTH_REVERSAL_TESTS.each_index do |n|
      test_settings = LITLE_AUTH_REVERSAL_TESTS[n]
      capture_txns << [test_settings[:capture_amount], responses[n].authorization, authorization_txns[n].last] if test_settings[:capture_amount] > 0
    end
    assert capture_responses = @gateway.capture(capture_txns)
    assert capture_responses.all? { |r| r.params['litle_txn_type'] == 'capture' }
    assert_equal(2, capture_responses.size)
    assert capture_responses.all? { |r| r.success? }

    void_txns = (0..3).map { |n| [LITLE_AUTH_REVERSAL_TESTS[n][:reversal_amount], authorizations[n]] }
    assert void_responses = @gateway.void(void_txns)
    assert void_responses.all? { |r| r.params['litle_txn_type'] == 'authReversal' }
    assert_equal(4, void_responses.size)
    void_responses.each_index do |n|
      verify_auth_reversal_response(n, void_responses[n-1])
    end
  end

  def test_non_litle_credit
    (1..5).each do |n|
      amount, card, options = setup_authorize n
      assert response = @gateway.credit(amount, card, options)
      assert_success response
      assert_equal('credit', response.params['litle_txn_type'])
    end

    # batch
    credit_txns = (1..5).map {|n| setup_authorize n}
    responses = @gateway.credit(credit_txns)
    assert responses.all? { |r| r.params['litle_txn_type'] == 'credit' }
    assert_equal(5, responses.size)
    assert responses.inject {|success, r| success and r.success?}

  end

  def test_invalid_login
    amount, card, options = setup_authorize 1
    gateway = LitleGateway.new(
                :login => '',
                :password => ''
              )
    assert response = gateway.authorize(100, card, options)
    assert_failure response
    assert_equal 'System Error - Call Litle & Co.', response.message
  end

  def test_request_for_response
    assert responses = @gateway.request_for_response('27512132609')
  end

  def test_empty_batch_request
    response = @gateway.authorize([])
    assert response.empty?
  end

  def test_partial_capture
    amount, card, options = setup_authorize 1
    assert response = @gateway.authorize(amount, card, options)
    verify_authorize_response(1, response)

    options[:partial] = true
    assert response = @gateway.capture(amount/2, response.authorization, options)
    assert response.params['litle_txn_type'] == 'capture'
    assert response.success?
  end


  private
  def setup_authorize(n)
    card = credit_card(fixtures("litle_card_#{n}".to_sym))
    card.valid?
    assert_equal(LITLE_AUTHORIZATION_TESTS[n-1][:type], card.type)
    options = {:order_id => n}
    begin
      options[:billing_address] = fixtures("litle_address_#{n}".to_sym)
    rescue StandardError
    end
    amount = "#{n}00#{n}0".to_i
    [amount, card, options]
  end

  def run_authorize_capture_credit_void_test(n)
    amount, card, options = setup_authorize n
    assert response = @gateway.authorize(amount, card, options)
    verify_authorize_response(n, response)

    # test capture and credit
    if response.success?
      assert response = @gateway.capture(amount, response.authorization, options)
      assert response.success?
      assert_equal('capture', response.params['litle_txn_type'])

      assert response = @gateway.credit(amount, response.authorization, options)
      assert response.success?
      assert_equal('credit', response.params['litle_txn_type'])

      assert response = @gateway.void(response.authorization)
      assert response.success?
      assert_equal('void', response.params['litle_txn_type'])
    end
  end

  def run_authorize_auth_reversal_test(n)
    amount, card, options = setup_authorize n
    assert response = @gateway.authorize(amount, card, options)

    if response.success?
      test_settings = LITLE_AUTH_REVERSAL_TESTS[n-1]
      if test_settings[:capture_amount] > 0
        assert capture_response = @gateway.capture(test_settings[:capture_amount], response.authorization, options)
        assert capture_response.success?
      end
      assert response = @gateway.void(test_settings[:reversal_amount], response.authorization)
      verify_auth_reversal_response(n, response)
    end
  end

  def run_purchase_void_test(n)
    amount, card, options = setup_authorize n
    assert response = @gateway.purchase(amount, card, options)
    verify_authorize_response(n, response)
    if response.success?
      assert response = @gateway.void(response.authorization)
      assert response.success?
    end
  end

  def verify_authorize_response(n, response)
    expected = LITLE_AUTHORIZATION_TESTS[n-1]
    assert_equal(expected[:success], response.success?)
    assert_equal(expected[:avs_result_code], response.avs_result['code'])
    assert_equal(expected[:cvv_result_code], response.cvv_result['code'])
    # Litle specific
    assert_equal(expected[:response_code], response.params['response'])
    assert_equal(LitleGateway::RESPONSE_CODES[response.params['response']], response.message)
    assert_equal(expected[:auth_code], response.params['auth_code'])
    assert_equal(n.to_s, response.params['order_id'])
  end

  def verify_auth_reversal_response(n, response)
    test_settings = LITLE_AUTH_REVERSAL_TESTS[n-1]
    assert_equal('authReversal', response.params['litle_txn_type'])
    assert_equal(test_settings[:success], response.success?)
    assert_equal(test_settings[:response_code], response.params['response'])
    assert_equal(LitleGateway::RESPONSE_CODES[response.params['response']], response.message)
  end
end


