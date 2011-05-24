#   Copyright (c) 2010, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

class Contact < ActiveRecord::Base
  belongs_to :user
  validates_presence_of :user

  belongs_to :person
  validates_presence_of :person

  has_one :client
  has_one :access_token
  has_one :refresh_token

  has_many :aspect_memberships
  has_many :aspects, :through => :aspect_memberships

  has_many :post_visibilities
  has_many :posts, :through => :post_visibilities

  validate :not_contact_for_self

  validates_uniqueness_of :person_id, :scope => :user_id

  scope :sharing, lambda {
    where(:sharing => true)
  }

  scope :receiving, lambda {
    where(:receiving => true)
  }

  before_destroy :destroy_notifications
  def destroy_notifications
    Notification.where(:target_type => "Person",
                       :target_id => person_id,
                       :recipient_id => user_id,
                      :type => "Notifications::StartedSharing").delete_all
  end

  def dispatch_request
    request = self.generate_request

    # to create oauth token, we must save the unpersisted contact
    self.save
    Client.create!(:contact => self)
    Postzord::Dispatch.new(self.user, request).post
    request
  end

  def generate_request
    Request.diaspora_initialize(:from => self.user.person,
                :to => self.person,
                :into => aspects.first)
  end

  def receive_post(post)
    PostVisibility.create!(:post_id => post.id, :contact_id => self.id)
    self.user.notify_if_mentioned(post)
    post.socket_to_user(self.user, :aspect_ids => self.aspect_ids) if post.respond_to? :socket_to_user
  end

  def contacts
    people = Person.arel_table
    incoming_aspects = Aspect.joins(:contacts).where(
      :user_id => self.person.owner_id,
      :contacts_visible => true,
      :contacts => {:person_id => self.user.person.id}).select('aspects.id')
    incoming_aspect_ids = incoming_aspects.map{|a| a.id}
    similar_contacts = Person.joins(:contacts => :aspect_memberships).where(
      :aspect_memberships => {:aspect_id => incoming_aspect_ids}).where(people[:id].not_eq(self.user.person.id)).select('DISTINCT people.*')
  end

  def mutual?
    self.sharing && self.receiving
  end

  def receive_tokens
    sender = self.person
    recipient = self.user

    if refresh_token.nil? || refresh_token.expired?
      time = Time.now
      nonce = SecureToken.generate(32)
      challenge = [sender.diaspora_handle, recipient.diaspora_handle, time.to_i, nonce].join(';')
      sig = Base64.encode64(recipient.encryption_key.sign(OpenSSL::Digest::SHA256.new, challenge))

      client = Rack::OAuth2::Client.new(
        :identifier => "#{sender.diaspora_handle};#{recipient.diaspora_handle}",
        :secret => Base64.encode64("#{time.to_i};#{nonce};#{sig}"),
        #:redirect_uri => YOUR_REDIRECT_URI, # only required for grant_type = :code
        :host => URI.parse(sender.url).host,
        :port => URI.parse(sender.url).port.to_s,
        :time => time.to_i.to_s
      )

      save_tokens(client.access_token!)

    else
       client = Rack::OAuth2::Client.new(
        :identifier => "#{sender.diaspora_handle};#{recipient.diaspora_handle}",
        :secret => refresh_token.token,
        #:redirect_uri => YOUR_REDIRECT_URI, # only required for grant_type = :code
        :host => URI.parse(sender.url).host,
        :port => URI.parse(sender.url).port.to_s,
        :time => time.to_i.to_s
      )

      client.refresh_token = refresh_token.token

      response = client.access_token!
      access_token = AccessToken.create!(:token => response.access_token, :refresh_token => refresh_token, :contact => self)
    end

    self.save
  end

  def save_tokens(bearer_token)
    response = bearer_token.token_response
    refresh_token = RefreshToken.find_or_create_by_token_and_contact_id(response[:refresh_token], self.id)
    access_token = AccessToken.create!(:token => response[:access_token], :refresh_token => refresh_token, :contact => self)
  end

  private
  def not_contact_for_self
    if person_id && person.owner == user
      errors[:base] << 'Cannot create self-contact'
    end
  end
end

