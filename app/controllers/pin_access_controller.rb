# frozen_string_literal: true

class PinAccessController < ApplicationController
  SINGLETON_EMAIL = "streamvault@localhost"

  before_action :redirect_authenticated_user, only: %i[new create]

  def new
    prepare_pin_state
  end

  def create
    prepare_pin_state

    if @setup
      configure_pin
    else
      unlock
    end
  end

  def destroy
    sign_out(:user)
    redirect_to new_user_session_path, notice: "StreamVault is locked."
  end

  private

  def prepare_pin_state
    @user = User.first || User.new(email: SINGLETON_EMAIL)
    @setup = !@user.pin_configured?
    @pin_errors = []
  end

  def configure_pin
    if @user.set_pin(params[:pin], params[:pin_confirmation])
      sign_in_and_redirect(@user)
    else
      render_pin_errors(@user.errors.full_messages)
    end
  end

  def unlock
    if @user.valid_pin?(params[:pin])
      sign_in_and_redirect(@user)
    else
      render_pin_errors([ "Incorrect PIN." ])
    end
  end

  def sign_in_and_redirect(user)
    sign_in(user)
    redirect_to root_path
  end

  def render_pin_errors(errors)
    @pin_errors = errors
    render :new, status: :unprocessable_entity
  end

  def redirect_authenticated_user
    redirect_to root_path if user_signed_in?
  end
end
