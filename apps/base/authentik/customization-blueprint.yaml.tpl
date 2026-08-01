version: 1
metadata:
  name: Homelab login customization
entries:
  - model: authentik_sources_oauth.oauthsource
    id: github-source
    identifiers:
      slug: github
    attrs:
      name: GitHub
      enabled: true
      promoted: true
      user_matching_mode: email_link
      authentication_flow: !Find [authentik_flows.flow, [slug, default-source-authentication]]
      enrollment_flow: !Find [authentik_flows.flow, [slug, default-source-enrollment]]
      provider_type: github
      authorization_url: https://github.com/login/oauth/authorize
      access_token_url: https://github.com/login/oauth/access_token
      profile_url: https://api.github.com/user
      authorization_code_auth_method: post_body
      consumer_key: !Env [AUTHENTIK_GITHUB_CLIENT_ID, ""]
      consumer_secret: !Env [AUTHENTIK_GITHUB_CLIENT_SECRET, ""]
  - model: authentik_sources_oauth.oauthsource
    id: google-source
    identifiers:
      slug: google
    attrs:
      name: Google
      enabled: true
      promoted: true
      user_matching_mode: email_link
      authentication_flow: !Find [authentik_flows.flow, [slug, default-source-authentication]]
      enrollment_flow: !Find [authentik_flows.flow, [slug, default-source-enrollment]]
      provider_type: google
      authorization_url: https://accounts.google.com/o/oauth2/auth
      access_token_url: https://oauth2.googleapis.com/token
      profile_url: https://www.googleapis.com/oauth2/v1/userinfo
      authorization_code_auth_method: post_body
      consumer_key: !Env [AUTHENTIK_GOOGLE_CLIENT_ID, ""]
      consumer_secret: !Env [AUTHENTIK_GOOGLE_CLIENT_SECRET, ""]
  - model: authentik_flows.flow
    id: recovery-flow
    identifiers:
      slug: default-recovery-flow
    attrs:
      name: Default recovery flow
      title: Reset your password
      designation: recovery
      authentication: require_token
  - model: authentik_stages_prompt.prompt
    id: recovery-password
    identifiers:
      name: default-recovery-field-password
    attrs:
      field_key: password
      label: Password
      type: password
      required: true
      placeholder: Password
      order: 0
      placeholder_expression: false
  - model: authentik_stages_prompt.prompt
    id: recovery-password-repeat
    identifiers:
      name: default-recovery-field-password-repeat
    attrs:
      field_key: password_repeat
      label: Password (repeat)
      type: password
      required: true
      placeholder: Password (repeat)
      order: 1
      placeholder_expression: false
  - model: authentik_stages_prompt.promptstage
    id: recovery-password-stage
    identifiers:
      name: Set a local password
    attrs:
      fields:
        - !KeyOf recovery-password
        - !KeyOf recovery-password-repeat
      validation_policies: []
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !Find [authentik_flows.flow, [slug, default-source-enrollment]]
      stage: !KeyOf recovery-password-stage
      order: -1
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      policy_engine_mode: any
      invalid_response_action: retry
  - model: authentik_stages_user_write.userwritestage
    id: recovery-user-write
    identifiers:
      name: default-recovery-user-write
    attrs:
      user_creation_mode: never_create
  - model: authentik_stages_user_login.userloginstage
    id: recovery-user-login
    identifiers:
      name: default-recovery-user-login
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !KeyOf recovery-flow
      stage: !KeyOf recovery-password-stage
      order: 10
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      policy_engine_mode: any
      invalid_response_action: retry
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !KeyOf recovery-flow
      stage: !KeyOf recovery-user-write
      order: 20
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      policy_engine_mode: any
      invalid_response_action: retry
  - model: authentik_flows.flowstagebinding
    identifiers:
      target: !KeyOf recovery-flow
      stage: !KeyOf recovery-user-login
      order: 100
    attrs:
      evaluate_on_plan: true
      re_evaluate_policies: false
      policy_engine_mode: any
      invalid_response_action: retry
  - model: authentik_flows.flow
    identifiers:
      slug: default-authentication-flow
    attrs:
      name: Welcome to Harville Homelab!
      title: Welcome to Harville Homelab!
  - model: authentik_stages_identification.identificationstage
    identifiers:
      name: default-authentication-identification
    attrs:
      sources:
        - !KeyOf github-source
        - !KeyOf google-source
      show_source_labels: true
  - model: authentik_brands.brand
    identifiers:
      domain: authentik-default
    attrs:
      branding_title: Harville Homelab
      branding_default_flow_background: /static/dist/assets/images/homelab-login-background.jpg
      flow_recovery: !KeyOf recovery-flow
# authentik-social-mac: __AUTHENTIK_SOCIAL_SECRET_VERSION__
