# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_26_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness",
      unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "answer_options", force: :cascade do |t|
    t.boolean "correct", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "position", null: false
    t.bigint "question_id", null: false
    t.text "rationale"
    t.text "rationale_note"
    t.string "rationale_verdict"
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["question_id", "position"], name: "index_answer_options_on_question_id_and_position", unique: true
    t.index ["question_id"], name: "index_answer_options_on_question_id"
  end

  create_table "answers", force: :cascade do |t|
    t.bigint "answer_option_id"
    t.datetime "answered_at", null: false
    t.string "confidence"
    t.boolean "correct", default: false, null: false
    t.datetime "created_at", null: false
    t.string "error_reason"
    t.bigint "exam_question_id", null: false
    t.integer "seconds_spent", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["answer_option_id"], name: "index_answers_on_answer_option_id"
    t.index ["answered_at"], name: "index_answers_on_answered_at"
    t.index ["exam_question_id"], name: "index_answers_on_exam_question_id", unique: true
  end

  create_table "branches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.string "slug", null: false
    t.bigint "specialty_id", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_branches_on_slug", unique: true
    t.index ["specialty_id", "position"], name: "index_branches_on_specialty_id_and_position"
    t.index ["specialty_id"], name: "index_branches_on_specialty_id"
  end

  create_table "clinical_cases", force: :cascade do |t|
    t.bigint "clinical_image_id"
    t.datetime "created_at", null: false
    t.string "difficulty", default: "medium", null: false
    t.string "export_key", null: false
    t.bigint "generation_run_id"
    t.bigint "guideline_id"
    t.string "locale", default: "es", null: false
    t.bigint "setting_id"
    t.string "source", default: "gpc_generated", null: false
    t.bigint "specialty_id"
    t.string "status", default: "draft", null: false
    t.text "stem", null: false
    t.bigint "topic_id"
    t.datetime "updated_at", null: false
    t.text "verification_notes"
    t.string "verification_verdict"
    t.datetime "verified_at"
    t.index ["clinical_image_id"], name: "index_clinical_cases_on_clinical_image_id"
    t.index ["export_key"], name: "index_clinical_cases_on_export_key", unique: true
    t.index ["generation_run_id"], name: "index_clinical_cases_on_generation_run_id"
    t.index ["guideline_id"], name: "index_clinical_cases_on_guideline_id"
    t.index ["setting_id"], name: "index_clinical_cases_on_setting_id"
    t.index ["specialty_id"], name: "index_clinical_cases_on_specialty_id"
    t.index ["status", "difficulty"], name: "index_clinical_cases_on_status_and_difficulty"
    t.index ["topic_id", "status"], name: "index_clinical_cases_on_topic_id_and_status"
    t.index ["topic_id"], name: "index_clinical_cases_on_topic_id"
    t.index ["verification_verdict"], name: "index_clinical_cases_on_verification_verdict"
  end

  create_table "clinical_images", force: :cascade do |t|
    t.string "attribution", null: false
    t.string "caption"
    t.datetime "created_at", null: false
    t.bigint "guideline_section_id", null: false
    t.string "kind", default: "figure", null: false
    t.string "label", null: false
    t.integer "position", null: false
    t.string "remote_path", null: false
    t.string "source", default: "gpc", null: false
    t.datetime "updated_at", null: false
    t.index ["guideline_section_id", "position"], name: "index_clinical_images_on_guideline_section_id_and_position",
      unique: true
    t.index ["guideline_section_id"], name: "index_clinical_images_on_guideline_section_id"
    t.index ["kind"], name: "index_clinical_images_on_kind"
    t.index ["label"], name: "index_clinical_images_on_label"
  end

  create_table "entitlements", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "MXN", null: false
    t.string "dispute_id"
    t.string "dispute_status"
    t.datetime "disputed_at"
    t.datetime "expires_at", null: false
    t.string "external_id", null: false
    t.string "plan", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.decimal "refunded_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "refunded_at"
    t.string "source", null: false
    t.datetime "starts_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index "((raw_payload ->> 'payment_intent'::text))", name: "index_entitlements_on_payment_intent"
    t.index ["source", "external_id"], name: "index_entitlements_on_source_and_external_id", unique: true
    t.index ["user_id", "expires_at"], name: "index_entitlements_on_user_id_and_expires_at"
  end

  create_table "exam_questions", force: :cascade do |t|
    t.bigint "clinical_case_id", null: false
    t.datetime "created_at", null: false
    t.bigint "exam_id", null: false
    t.integer "position", null: false
    t.bigint "question_id", null: false
    t.datetime "updated_at", null: false
    t.index ["clinical_case_id"], name: "index_exam_questions_on_clinical_case_id"
    t.index ["exam_id", "position"], name: "index_exam_questions_on_exam_id_and_position", unique: true
    t.index ["exam_id", "question_id"], name: "index_exam_questions_on_exam_id_and_question_id", unique: true
    t.index ["question_id"], name: "index_exam_questions_on_question_id"
  end

  create_table "exams", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "elapsed_seconds", default: 0, null: false
    t.string "feedback_timing", default: "after_each", null: false
    t.jsonb "filters", default: {}, null: false
    t.string "mode", null: false
    t.integer "question_count", null: false
    t.datetime "running_since"
    t.decimal "score", precision: 5, scale: 2
    t.integer "seconds_per_question"
    t.datetime "started_at", null: false
    t.string "status", default: "in_progress", null: false
    t.integer "time_limit_seconds"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "status"], name: "index_exams_on_user_id_and_status"
  end

  create_table "generation_runs", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.integer "calls", default: 0, null: false
    t.integer "cases_created", default: 0, null: false
    t.decimal "cost_usd", precision: 12, scale: 8, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "export_key", null: false
    t.datetime "finished_at"
    t.integer "input_tokens", default: 0, null: false
    t.string "model", null: false
    t.text "notes"
    t.integer "output_tokens", default: 0, null: false
    t.string "provider", null: false
    t.string "purpose", null: false
    t.jsonb "rejection_reasons", default: {}, null: false
    t.integer "rejections", default: 0, null: false
    t.datetime "started_at"
    t.string "status", default: "running", null: false
    t.datetime "updated_at", null: false
    t.index ["export_key"], name: "index_generation_runs_on_export_key", unique: true
    t.index ["provider", "model"], name: "index_generation_runs_on_provider_and_model"
    t.index ["status"], name: "index_generation_runs_on_status"
  end

  create_table "guideline_sections", force: :cascade do |t|
    t.text "body", null: false
    t.string "chapter"
    t.text "clinical_question"
    t.string "content_hash", null: false
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.bigint "guideline_id", null: false
    t.string "heading", null: false
    t.string "kind", null: false
    t.integer "position", null: false
    t.string "question_label"
    t.bigint "source_section_id"
    t.datetime "updated_at", null: false
    t.index ["guideline_id", "external_id"], name: "index_guideline_sections_on_guideline_id_and_external_id",
      unique: true
    t.index ["guideline_id", "position"], name: "index_guideline_sections_on_guideline_id_and_position"
    t.index ["guideline_id"], name: "index_guideline_sections_on_guideline_id"
    t.index ["kind"], name: "index_guideline_sections_on_kind"
    t.index ["source_section_id"], name: "index_guideline_sections_on_source_section_id"
  end

  create_table "guideline_topics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "guideline_id", null: false
    t.float "relevance", default: 0.0, null: false
    t.bigint "topic_id", null: false
    t.datetime "updated_at", null: false
    t.index ["guideline_id", "topic_id"], name: "index_guideline_topics_on_guideline_id_and_topic_id", unique: true
    t.index ["guideline_id"], name: "index_guideline_topics_on_guideline_id"
    t.index ["relevance"], name: "index_guideline_topics_on_relevance"
    t.index ["topic_id"], name: "index_guideline_topics_on_topic_id"
  end

  create_table "guidelines", force: :cascade do |t|
    t.string "catalog_key", null: false
    t.string "catalog_url"
    t.string "content_hash", null: false
    t.datetime "created_at", null: false
    t.string "document_url"
    t.string "enarm_relevance"
    t.string "external_id"
    t.datetime "ingested_at"
    t.string "institution", null: false
    t.jsonb "levels_of_care", default: [], null: false
    t.string "relevance_note"
    t.string "source", null: false
    t.jsonb "specialty_labels", default: [], null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["catalog_key"], name: "index_guidelines_on_catalog_key", unique: true
    t.index ["enarm_relevance"], name: "index_guidelines_on_enarm_relevance"
    t.index ["institution"], name: "index_guidelines_on_institution"
    t.index ["specialty_labels"], name: "index_guidelines_on_specialty_labels", using: :gin
    t.index ["year"], name: "index_guidelines_on_year"
  end

  create_table "identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "provider", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["provider", "uid"], name: "index_identities_on_provider_and_uid", unique: true
    t.index ["user_id", "provider"], name: "index_identities_on_user_id_and_provider", unique: true
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "auth_key", null: false
    t.datetime "created_at", null: false
    t.text "endpoint", null: false
    t.string "p256dh_key", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["endpoint"], name: "index_push_subscriptions_on_endpoint", unique: true
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "question_reports", force: :cascade do |t|
    t.text "comment"
    t.datetime "created_at", null: false
    t.bigint "question_id", null: false
    t.string "reason", null: false
    t.text "resolution_note"
    t.datetime "resolved_at"
    t.bigint "resolved_by_id"
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["question_id"], name: "index_question_reports_on_question_id"
    t.index ["resolved_by_id"], name: "index_question_reports_on_resolved_by_id"
    t.index ["status", "created_at"], name: "index_question_reports_on_status_and_created_at"
    t.index ["user_id", "question_id"], name: "index_question_reports_one_open_per_user", unique: true,
      where: "((status)::text = 'open'::text)"
  end

  create_table "questions", force: :cascade do |t|
    t.bigint "clinical_case_id", null: false
    t.datetime "created_at", null: false
    t.text "explanation"
    t.integer "position", null: false
    t.bigint "recommendation_id"
    t.text "source_quote"
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["clinical_case_id", "position"], name: "index_questions_on_clinical_case_id_and_position", unique: true
    t.index ["clinical_case_id"], name: "index_questions_on_clinical_case_id"
    t.index ["recommendation_id"], name: "index_questions_on_recommendation_id"
  end

  create_table "recommendations", force: :cascade do |t|
    t.string "citation"
    t.datetime "created_at", null: false
    t.string "decision_kind"
    t.string "grade"
    t.bigint "guideline_section_id", null: false
    t.string "label", null: false
    t.integer "position", null: false
    t.string "scale"
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.index ["decision_kind"], name: "index_recommendations_on_decision_kind"
    t.index ["grade"], name: "index_recommendations_on_grade"
    t.index ["guideline_section_id", "position"], name: "index_recommendations_on_guideline_section_id_and_position",
      unique: true
    t.index ["guideline_section_id"], name: "index_recommendations_on_guideline_section_id"
    t.index ["scale"], name: "index_recommendations_on_scale"
  end

  create_table "reminder_deliveries", force: :cascade do |t|
    t.jsonb "channels", default: [], null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.date "local_date", null: false
    t.string "slot", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "local_date", "slot"], name: "index_reminder_deliveries_on_user_id_and_local_date_and_slot",
      unique: true
  end

  create_table "reminder_preferences", force: :cascade do |t|
    t.boolean "by_email", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "exam_countdown", default: false, null: false
    t.integer "minute_of_day", default: 480, null: false
    t.boolean "streak_at_risk", default: false, null: false
    t.boolean "study_days", default: false, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_reminder_preferences_on_user_id", unique: true
  end

  create_table "review_cards", force: :cascade do |t|
    t.bigint "clinical_case_id"
    t.datetime "created_at", null: false
    t.date "due_on", null: false
    t.decimal "ease_factor", precision: 4, scale: 2, default: "2.5", null: false
    t.integer "interval_days", default: 0, null: false
    t.integer "lapses", default: 0, null: false
    t.date "last_reviewed_on"
    t.bigint "recommendation_id"
    t.integer "repetitions", default: 0, null: false
    t.integer "reviews_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["clinical_case_id"], name: "index_review_cards_on_clinical_case_id"
    t.index ["recommendation_id"], name: "index_review_cards_on_recommendation_id"
    t.index ["user_id", "clinical_case_id"], name: "index_review_cards_on_user_id_and_clinical_case_id", unique: true,
      where: "(clinical_case_id IS NOT NULL)"
    t.index ["user_id", "due_on"], name: "index_review_cards_on_user_id_and_due_on"
    t.index ["user_id", "recommendation_id"], name: "index_review_cards_on_user_id_and_recommendation_id",
      unique: true, where: "(recommendation_id IS NOT NULL)"
    t.check_constraint "num_nonnulls(clinical_case_id, recommendation_id) = 1", name: "review_cards_one_subject"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.integer "completed_jobs", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.datetime "enqueued_at"
    t.datetime "failed_at"
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "finished_at"
    t.text "metadata"
    t.text "on_failure"
    t.text "on_finish"
    t.text "on_success"
    t.integer "total_jobs", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.bigint "batch_id"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "specialties", force: :cascade do |t|
    t.string "color_token", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_specialties_on_slug", unique: true
  end

  create_table "study_days", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.integer "pearls_reviewed", default: 0, null: false
    t.integer "questions_answered", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "date"], name: "index_study_days_on_user_id_and_date", unique: true
  end

  create_table "study_plan_day_topics", force: :cascade do |t|
    t.integer "position", null: false
    t.bigint "study_plan_day_id", null: false
    t.bigint "topic_id", null: false
    t.index ["study_plan_day_id", "topic_id"], name: "index_study_plan_day_topics_on_study_plan_day_id_and_topic_id",
      unique: true
    t.index ["topic_id"], name: "index_study_plan_day_topics_on_topic_id"
  end

  create_table "study_plan_days", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.bigint "exam_id"
    t.string "kind", null: false
    t.integer "pass_number", null: false
    t.bigint "specialty_id"
    t.bigint "study_plan_id", null: false
    t.datetime "updated_at", null: false
    t.index ["exam_id"], name: "index_study_plan_days_on_exam_id"
    t.index ["specialty_id"], name: "index_study_plan_days_on_specialty_id"
    t.index ["study_plan_id", "date"], name: "index_study_plan_days_on_study_plan_id_and_date", unique: true
  end

  create_table "study_plans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "exam_date", null: false
    t.date "starts_on", null: false
    t.string "template", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_study_plans_on_user_id", unique: true
  end

  create_table "topics", force: :cascade do |t|
    t.jsonb "aliases", default: [], null: false
    t.bigint "branch_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["branch_id", "position"], name: "index_topics_on_branch_id_and_position"
    t.index ["branch_id"], name: "index_topics_on_branch_id"
    t.index ["slug"], name: "index_topics_on_slug", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "email_verified_at"
    t.string "first_name", null: false
    t.datetime "granted_premium_until"
    t.string "last_name"
    t.string "locale", default: "es", null: false
    t.string "password_digest"
    t.string "role", default: "student", null: false
    t.string "time_zone", default: "America/Mexico_City", null: false
    t.datetime "trial_ends_at"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["granted_premium_until"], name: "index_users_on_granted_premium_until"
  end

  create_table "webhook_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "external_id", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "external_id"], name: "index_webhook_events_on_provider_and_external_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "answer_options", "questions"
  add_foreign_key "answers", "answer_options"
  add_foreign_key "answers", "exam_questions"
  add_foreign_key "branches", "specialties"
  add_foreign_key "clinical_cases", "clinical_images"
  add_foreign_key "clinical_cases", "generation_runs"
  add_foreign_key "clinical_cases", "guidelines"
  add_foreign_key "clinical_cases", "specialties"
  add_foreign_key "clinical_cases", "specialties", column: "setting_id"
  add_foreign_key "clinical_cases", "topics"
  add_foreign_key "clinical_images", "guideline_sections"
  add_foreign_key "entitlements", "users"
  add_foreign_key "exam_questions", "clinical_cases"
  add_foreign_key "exam_questions", "exams"
  add_foreign_key "exam_questions", "questions"
  add_foreign_key "exams", "users"
  add_foreign_key "guideline_sections", "guideline_sections", column: "source_section_id"
  add_foreign_key "guideline_sections", "guidelines"
  add_foreign_key "guideline_topics", "guidelines"
  add_foreign_key "guideline_topics", "topics"
  add_foreign_key "identities", "users"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "question_reports", "questions"
  add_foreign_key "question_reports", "users"
  add_foreign_key "question_reports", "users", column: "resolved_by_id"
  add_foreign_key "questions", "clinical_cases"
  add_foreign_key "questions", "recommendations"
  add_foreign_key "recommendations", "guideline_sections"
  add_foreign_key "reminder_deliveries", "users"
  add_foreign_key "reminder_preferences", "users"
  add_foreign_key "review_cards", "clinical_cases", on_delete: :cascade
  add_foreign_key "review_cards", "recommendations", on_delete: :cascade
  add_foreign_key "review_cards", "users", on_delete: :cascade
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "study_days", "users"
  add_foreign_key "study_plan_day_topics", "study_plan_days"
  add_foreign_key "study_plan_day_topics", "topics"
  add_foreign_key "study_plan_days", "exams", on_delete: :nullify
  add_foreign_key "study_plan_days", "specialties"
  add_foreign_key "study_plan_days", "study_plans"
  add_foreign_key "study_plans", "users"
  add_foreign_key "topics", "branches"
end
