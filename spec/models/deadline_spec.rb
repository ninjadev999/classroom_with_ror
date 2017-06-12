# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AssignmentInvitation, type: :model do
  describe 'deadline_at' do
    it 'must be present' do
      deadline = build(:deadline, deadline_at: nil)
      deadline.save

      expect(deadline.errors[:deadline_at]).to_not be_empty
    end

    it 'must be in the future' do
      deadline = build(:deadline, deadline_at: Time.zone.yesterday)
      deadline.save

      expect(deadline.errors[:deadline_at]).to_not be_empty
    end
  end

  describe '#passed?' do
    it 'is correct' do
      passed_deadline = create(:deadline)
      passed_deadline.update_attribute(:deadline_at, Time.zone.yesterday)

      not_passed_deadline = create(:deadline, deadline_at: Time.zone.tomorrow)

      expect(passed_deadline.passed?).to be_truthy
      expect(not_passed_deadline.passed?).to be_falsey
    end
  end

  describe '#create_job' do
    it 'enqueues correct job' do
      deadline = create(:deadline)
      ActiveJob::Base.queue_adapter = :test

      expect {
        deadline.create_job
      }.to have_enqueued_job(DeadlineJob).with(deadline.id)
    end
  end
end
