namespace :gpc do
  desc "Read the live catalog and upsert Guideline rows"
  task catalog: :environment do
    fetched = Gpc::LiveCatalogFetcher.call
    abort(fetched.errors.full_messages.to_sentence) unless fetched.success?

    imported = Gpc::CatalogImporter.call(fetched.payload)
    abort(imported.errors.full_messages.to_sentence) unless imported.success?

    puts imported.payload.map { |key, value| "#{key}: #{value}" }.join(", ")
  end

  desc "Enqueue every guideline summary the Wayback Machine holds for CENETEC"
  task archive: :environment do
    fetched = Gpc::ArchiveCatalogFetcher.call
    abort(fetched.errors.full_messages.to_sentence) unless fetched.success?

    entries = fetched.payload
    entries.each { |entry| Gpc::IngestArchivedGuidelineJob.perform_later(entry) }

    puts "#{entries.size} guías archivadas encoladas en la cola ingestion"
  end

  desc "Re-derive archived guideline titles from stored text, without refetching"
  task retitle: :environment do
    result = Gpc::Retitler.call
    abort(result.errors.full_messages.to_sentence) unless result.success?

    puts result.payload.map { |key, value| "#{key}: #{value}" }.join(", ")
  end

  desc "Link every guideline to the topics its title names"
  task link: :environment do
    result = Gpc::TopicLinker.call
    abort(result.errors.full_messages.to_sentence) unless result.success?

    puts result.payload.map { |key, value| "#{key}: #{value}" }.join(", ")
  end

  desc "Write guidelines and their sections to a portable file [path]"
  task :export, [:path] => :environment do |_task, args|
    result = Gpc::CorpusExporter.call(args[:path] || "tmp/gpc-corpus.jsonl.gz")
    abort(result.errors.full_messages.to_sentence) unless result.success?

    payload = result.payload
    puts "#{payload[:path]} · #{payload[:guidelines]} guías · #{payload[:sections]} secciones · " \
         "#{ActiveSupport::NumberHelper.number_to_human_size(payload[:bytes])}"
  end

  desc "Load a file written by gpc:export into this database [path]"
  task :import, [:path] => :environment do |_task, args|
    result = Gpc::CorpusImporter.call(args[:path] || "tmp/gpc-corpus.jsonl.gz")
    abort(result.errors.full_messages.to_sentence) unless result.success?

    puts result.payload.map { |key, value| "#{key}: #{value}" }.join(", ")
    puts "Ahora corre gpc:reparse, taxonomy:seed y gpc:link para reconstruir lo derivado."
  end

  desc "Take citation text the PDF parser left inside statements out of them: " \
       "rake gpc:repair_statements[count] (count: statements)"
  task :repair_statements, [:count] => :environment do |_task, args|
    provider = Llm::Provider.for(:verifier)
    abort("Falta la clave del verificador. Revisa .env") unless provider.configured?

    run = GenerationRun.create!(
      purpose: "statement_repair", provider: provider.name, model: provider.model, started_at: Time.current
    )
    pending = Recommendation.actionable.repair_pending.order(:guideline_section_id, :position)
    totals = Hash.new(0)
    failures_in_a_row = 0
    Gpc::StatementRepairer.batches(pending.limit((args[:count] || 100).to_i).to_a).each do |batch|
      result = Gpc::StatementRepairer.call(batch, run: run)
      result.payload.each { |key, value| totals[key] += value }
      puts "#{batch.size} leídas#{" — #{result.errors.full_messages.to_sentence}" if result.failure?}"
      failures_in_a_row = result.success? ? 0 : failures_in_a_row + 1
      break if failures_in_a_row == 3
    end

    run.update!(status: failures_in_a_row == 3 ? "failed" : "completed", finished_at: Time.current)
    puts "\n#{totals.map { |key, value| "#{key}=#{value}" }.join(" ")} · pendientes #{pending.count} · " \
         "llamadas=#{run.calls} costo=$#{format("%.4f", run.cost_usd)}"
    puts "Detenida tras 3 fallas seguidas; no se reintentó." if run.status_failed?
  end

  desc "Write the statement repairs to a file another database can apply [path]"
  task :export_repairs, [:path] => :environment do |_task, args|
    result = Gpc::StatementRepairExporter.call(args[:path] || "tmp/statement-repairs.jsonl.gz")
    puts "#{result.payload[:path]} · #{result.payload[:statements]} recomendaciones"
  end

  desc "Apply a file written by gpc:export_repairs to this database [path]"
  task :import_repairs, [:path] => :environment do |_task, args|
    result = Gpc::StatementRepairImporter.call(args[:path] || "tmp/statement-repairs.jsonl.gz")
    abort(result.errors.full_messages.to_sentence) unless result.success?

    puts "aplicadas #{result.payload[:applied]} · sin encontrar #{result.payload[:missing]}"
  end

  desc "Re-read stored section bodies through the current parser, without touching the site"
  task reparse: :environment do
    result = Gpc::Reparser.call.payload

    result[:conflicts].each { |conflict| puts conflict }
    puts "#{result[:sections]} secciones · #{result[:before]} → #{result[:after]} recomendaciones"
    puts "archivo: #{result[:archived_recommendations]} recomendaciones de #{result[:archived_guidelines]} guías"
  end

  desc "Enqueue a full read of every live-site guideline's sections"
  task ingest: :environment do
    guidelines = Guideline.source_live_site
    guidelines.find_each { |guideline| Gpc::IngestGuidelineJob.perform_later(guideline) }

    puts "#{guidelines.count} guías encoladas en la cola ingestion"
  end

  desc "Re-read each live guideline's menu and store where its sections sit, without refetching bodies"
  task renav: :environment do
    result = Gpc::NavigationRefresher.call
    abort(result.errors.full_messages.to_sentence) unless result.success?

    puts result.payload.map { |key, value| "#{key}: #{value}" }.join(", ")
  end

  desc "Build the figure library from stored section text, downloading what is missing"
  task images: :environment do
    result = Gpc::ImageIngester.call
    puts result.payload.map { |key, value| "#{key}: #{value}" }.join(", ")
    # A partial run still reports its counts: one unreachable file is not a reason to
    # say nothing about the 900 that arrived. Response#errors is nil on success.
    puts result.errors.full_messages.first(10) if result.failure?
  end
end
