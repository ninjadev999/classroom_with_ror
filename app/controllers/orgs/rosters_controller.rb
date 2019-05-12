# frozen_string_literal: true

require 'google/apis/classroom_v1'

# rubocop:disable Metrics/ClassLength
module Orgs
  class RostersController < Orgs::Controller
    before_action :ensure_student_identifier_flipper_is_enabled

    before_action :ensure_current_roster,             except: %i[new create select_google_classroom import_from_google_classroom search_google_classroom]
    before_action :ensure_current_roster_entry,       except: %i[show new create remove_organization add_students select_google_classroom import_from_google_classroom search_google_classroom]
    before_action :ensure_enough_members_in_roster,   only: [:delete_entry]
    before_action :ensure_allowed_to_access_grouping, only: [:show]
    before_action :authorize_google_classroom,        only: %i[import_from_google_classroom select_google_classroom search_google_classroom]

    helper_method :current_roster, :unlinked_users, :authorize_google_classroom

    # rubocop:disable AbcSize
    def show
      @roster_entries = current_roster.roster_entries
        .includes(:user)
        .order(:identifier)
        .page(params[:roster_entries_page])

      @current_unlinked_users = User
        .where(id: unlinked_user_ids)
        .order(:id)
        .page(params[:unlinked_users_page])

      download_roster if params.dig("format")
    end
    # rubocop:enable AbcSize

    def new
      @roster = Roster.new
    end

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def create
      result = Roster::Creator.perform(
        organization: current_organization,
        identifier_name: "Identifiers",
        identifiers: params[:identifiers],
        google_user_ids: params[:google_user_ids],
      )

      # Set the object so that we can see errors when rendering :new
      @roster = result.roster

      if result.success?
        GitHubClassroom.statsd.increment("roster.create")

        flash[:success] = \
          "Your classroom roster has been saved! Manage it <a href='#{roster_url(current_organization)}'>here</a>."

        redirect_to organization_path(current_organization)
      else
        render :new
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    # rubocop:disable Metrics/AbcSize
    def remove_organization
      Organization.transaction do
        current_organization.update_attributes!(roster_id: nil)
        current_roster.destroy! if Organization.where(roster_id: current_roster.id).count.zero?
      end

      flash[:success] = "Roster successfully deleted!"
    rescue ActiveRecord::RecordInvalid
      flash[:error] = "An error has occured while trying to delete the roster. Please try again."
    ensure
      redirect_to organization_path(current_organization)
    end
    # rubocop:enable Metrics/AbcSize

    def link
      # Make sure the user is on the list
      user_id = params[:user_id].to_i
      raise ActiveRecord::ActiveRecordError unless unlinked_user_ids.include?(user_id)

      current_roster_entry.update_attributes!(user_id: user_id)

      flash[:success] = "Student and GitHub account linked!"
    rescue ActiveRecord::ActiveRecordError
      flash[:error] = "An error has occured, please try again."
    ensure
      redirect_to roster_path(current_organization)
    end

    def unlink
      current_roster_entry.update_attributes!(user_id: nil)

      flash[:success] = "Student and GitHub account unlinked!"
    rescue ActiveRecord::ActiveRecordError
      flash[:error] = "An error has occured, please try again."
    ensure
      redirect_to roster_path(current_organization)
    end

    def delete_entry
      current_roster_entry.destroy!

      flash[:success] = "Student successfully removed from roster!"
    rescue ActiveRecord::ActiveRecordError
      flash[:error] = "An error has occured, please try again."
    ensure
      redirect_to roster_path(current_organization)
    end

    # rubocop:disable Metrics/MethodLength
    # rubocop:disable Metrics/AbcSize
    def add_students
      identifiers = params[:identifiers].split("\r\n").reject(&:blank?).uniq

      begin
        entries = RosterEntry.create_entries(identifiers: identifiers, roster: current_roster)

        if entries.empty?
          flash[:warning] = "No students created."
        elsif entries.length == identifiers.length
          flash[:success] = "Students created."
        else
          flash[:success] = "Students created. Some duplicates have been omitted."
        end
      rescue RosterEntry::IdentifierCreationError
        flash[:error] = "An error has occured. Please try again."
      end

      redirect_to roster_path(current_organization)
    end

    def download_roster
      grouping = current_organization.groupings.find(params[:grouping]) if params[:grouping]

      user_to_groups = get_user_to_group_hash(grouping)

      @roster_entries = @current_roster.roster_entries.includes(:user).order(:identifier)
      respond_to do |format|
        format.csv do
          send_data(
            @roster_entries.to_csv(user_to_groups),
            filename:    "classroom_roster.csv",
            disposition: "attachment"
          )
        end
      end
    end
    # rubocop:enable Metrics/MethodLength
    # rubocop:enable Metrics/AbcSize

    def select_google_classroom
      @roster = Roster.new

      @google_classroom_courses = Kaminari
      .paginate_array(fetch_all_google_classrooms)
      .page(params[:page])
      .per(10)
    end

    def search_google_classroom
      courses_found = fetch_all_google_classrooms.select { |course|
        course.name.downcase.include? params[:query].downcase
      }

      response = Kaminari
      .paginate_array(courses_found)
      .page(params[:page])
      .per(10)

      respond_to do |format|
        format.html do
          render partial: "orgs/rosters/google_classroom_collection",
                 locals: { courses: response }
        end
      end
    end

    def import_from_google_classroom
      google_course_id = params[:course_id]
      students = @google_classroom_service.list_course_students(google_course_id).students
      if students.nil?
        flash[:warning] = "No new students were found in your Google Classroom."
        redirect_to organization_path(current_organization)
      else
        names = students.map {|s| s.profile.name.full_name }
        user_ids = students.map {|s| s.user_id }
        params[:identifiers] = names.join("\r\n")
        params[:google_user_ids] = user_ids

        current_organization.google_course_id = google_course_id
        create()
      end
    end

    private

    def current_roster
      return @current_roster if defined?(@current_roster)
      @current_roster = current_organization.roster
    end

    def current_roster_entry
      return @current_roster_entry if defined?(@current_roster_entry)
      @current_roster_entry = current_roster.roster_entries.find_by(id: params[:roster_entry_id])
    end

    def ensure_current_roster
      redirect_to new_roster_url(current_organization) if current_roster.nil?
    end

    def ensure_current_roster_entry
      not_found if current_roster_entry.nil?
    end

    def ensure_enough_members_in_roster
      return if current_roster.roster_entries.count > 1

      flash[:error] = "You cannot delete the last member of your roster!"
      redirect_to roster_url(current_organization)
    end

    def ensure_allowed_to_access_grouping
      return if params[:grouping].nil?

      not_found unless Grouping.find(params[:grouping]).organization_id == current_organization.id
    end

    # An unlinked user is a user who:
    # - Is a user on an assignment or group assignment belonging to the org
    # - Is not on the organization roster
    #
    # rubocop:disable Metrics/AbcSize
    def unlinked_user_ids
      return @unlinked_user_ids if defined?(@unlinked_user_ids)

      assignment_query = "assignment_repos.assignment_id IN (?) AND assignment_repos.user_id IS NOT NULL"
      assignments_ids  = current_organization.assignments.pluck(:id)
      assignment_users = AssignmentRepo.where(assignment_query, assignments_ids).pluck(:user_id).uniq

      roster_query       = "roster_entries.roster_id = ? AND roster_entries.user_id IS NOT NULL"
      roster_entry_users = RosterEntry.where(roster_query, current_roster.id).pluck(:user_id)

      group_assignment_query = "repo_accesses.organization_id = ? AND repo_accesses.user_id IS NOT NULL"
      group_assignment_users = RepoAccess.where(group_assignment_query, current_organization.id).pluck(:user_id)

      @unlinked_user_ids = (group_assignment_users + assignment_users).uniq - roster_entry_users
    end
    # rubocop:enable Metrics/AbcSize

    def unlinked_users
      return @unlinked_users if defined?(@unlinked_users)
      @unlinked_users = []

      result = User.where(id: unlinked_user_ids)

      result.each do |user|
        @unlinked_users.push(user)
      end

      @unlinked_users
    end

    # Maps user_ids to group names
    # If no grouping is specified it returns an empty hash
    def get_user_to_group_hash(grouping)
      mapping = {}
      return mapping unless grouping

      grouping.groups.each do |group|
        group.repo_accesses.map(&:user_id).each do |id|
          mapping[id] = group.title
        end
      end

      mapping
    end

    def fetch_all_google_classrooms
      next_page = nil
      courses = []
      begin
        response = @google_classroom_service.list_courses(page_size: 20, page_token: next_page)
        courses.push(*response.courses)

        next_page = response.next_page_token
      end while next_page

      return courses
    end

    def authorize_google_classroom
      google_classroom_client = GitHubClassroom.google_classroom_client

      if user_google_classroom_credentials.nil?
        redirect_to google_classroom_client.get_authorization_url(login_hint: current_user.github_user.login, request: request)
      end

      @google_classroom_service = Google::Apis::ClassroomV1::ClassroomService.new
      @google_classroom_service.client_options.application_name = "GitHub Classroom"
      @google_classroom_service.authorization = user_google_classroom_credentials
    end

    def user_google_classroom_credentials
      google_classroom_client = GitHubClassroom.google_classroom_client
      user_id = current_user.github_user.login

      google_classroom_client.get_credentials(user_id, request) rescue nil
    end
  end
end
# rubocop:enable Metrics/ClassLength
