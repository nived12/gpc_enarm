# The statement as a reader should see it, next to the parser's own text: an archived
# PDF's citation column sometimes bleeds into the statement ("hasta los 6 2007 meses"),
# and Gpc::StatementRepairer takes those fragments out. The parser's #text is left alone,
# because gpc:reparse matches rows by it and old citations quote it.
class AddRepairToRecommendations < ActiveRecord::Migration[8.1]
  def change
    change_table :recommendations, bulk: true do |t|
      t.text :clean_text
      t.jsonb :removed_fragments, null: false, default: []
      t.boolean :text_damaged, null: false, default: false
      t.datetime :repaired_at
    end
  end
end
