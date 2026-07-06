FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { "password123" }
    realdebrid_api_key { nil }
    # Set language defaults explicitly so the factory doesn't depend on
    # the before_validation :set_default_languages callback firing — if
    # that callback ever changes, every factory-built user would have
    # nil languages and fail validations downstream.
    preferred_languages { [ "ENG" ] }
    default_language { "ENG" }

    trait :with_realdebrid_key do
      realdebrid_api_key { "TEST_RD_KEY_#{SecureRandom.hex(8)}" }
    end
  end
end
