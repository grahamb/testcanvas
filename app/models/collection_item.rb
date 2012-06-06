#
# Copyright (C) 2012 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class CollectionItem < ActiveRecord::Base
  include Workflow
  include CustomValidations
  include SendToStream

  belongs_to :collection
  belongs_to :collection_item_data
  alias :data :collection_item_data
  belongs_to :user

  attr_accessible :collection, :collection_item_data, :user_comment, :user

  validates_presence_of :collection, :collection_item_data, :user
  validates_associated :collection_item_data
  validates_as_readonly :collection_item_data_id, :collection_id

  after_create :set_data_root_item

  # raises RecordNotFound if the collection is marked deleted or doesn't exist
  def active_collection
    col = self.collection
    raise ActiveRecord::RecordNotFound if !col || col.try(:deleted?)
    col
  end

  def set_data_root_item
    if self.collection_item_data && self.collection_item_data.root_item_id.nil?
      self.collection_item_data.update_attribute(:root_item_id, self.id)
    end
  end

  workflow do
    state :active
    state :deleted
  end

  named_scope :active, { :conditions => { :workflow_state => 'active' } }
  named_scope :newest_first, { :order => "id desc" }

  def discussion_topic
    DiscussionTopic.find_by_context_type_and_context_id(self.class.name, self.id) ||
      DiscussionTopic.new(:context => self, :discussion_type => DiscussionTopic::DiscussionTypes::FLAT)
  end

  def destroy
    self.workflow_state = 'deleted'
    save!
  end

  trigger.after(:insert) do |t|
    t.where("NEW.workflow_state = 'active'") do
      <<-SQL
      UPDATE collection_item_datas
      SET post_count = post_count + 1
      WHERE id = NEW.collection_item_data_id;
      SQL
    end
  end

  trigger.after(:update) do |t|
    t.where("NEW.workflow_state <> OLD.workflow_state") do
      <<-SQL
      UPDATE collection_item_datas
      SET post_count = post_count + CASE WHEN (NEW.workflow_state = 'active') THEN 1 ELSE -1 END
      WHERE id = NEW.collection_item_data_id;
      SQL
    end
  end

  trigger.after(:delete) do |t|
    t.where("OLD.workflow_state = 'active'") do
      <<-SQL
      UPDATE collection_item_datas
      SET post_count = post_count - 1
      WHERE id = OLD.collection_item_data_id;
      SQL
    end
  end

  set_policy do
    given { |user, session| self.collection.grants_right?(user, session, :read) }
    can :read

    given { |user, session| self.collection.grants_right?(user, session, :comment) }
    can :comment

    given { |user, session| self.collection.grants_right?(user, session, :create) }
    can :create

    given { |user, session| self.collection.grants_right?(user, session, :delete) }
    can :delete

    given { |user, session| self.collection.grants_right?(user, session, :update) }
    can :update

    given { |user| self.user == user }
    can :read and can :update and can :delete

    given { |user| self.collection.context.respond_to?(:has_member?) && self.collection.context.has_member?(user) }
    can :create
  end

  on_create_send_to_streams do
    (self.collection.try(:followers) || []) - [self.user]
  end
end
