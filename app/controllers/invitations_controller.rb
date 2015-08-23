class InvitationsController < ApplicationController
  before_action :set_invitation

  layout 'layouts/invitations'

  rescue_from GitHub::Forbidden, GitHub::Error, GitHub::NotFound, with: :error

  def show; end

  private

  def error(exception)
    flash[:error] = exception.message.present? ? exception.message : 'Uh oh, an error has occured.'
    redirect_path = case @invitation
                    when AssignmentInvitation
                      assignment_invitation_url(@invitation)
                    when GroupAssignmentInvitation
                      group_assignment_invitation_url(@invitation)
                    end

    redirect_to redirect_path
  end

  def ensure_logged_in
    return if logged_in?
    session[:pre_login_destination] = "#{request.base_url}#{request.path}"
    redirect_to login_path
  end
end
