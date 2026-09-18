# Pin npm packages by running ./bin/importmap

pin "application"
pin "anime4k"
pin "anime4k-ultra"
pin "anime4k-webgpu"
pin "anime4k-webgpu-ultra"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
