# A question's "best available answer" version for Modo ENARM: the same case and
# question with the ideal answer left out. It shares the original's position, so the
# position is unique only among originals.
class AddVariantOfToQuestions < ActiveRecord::Migration[8.1]
  def change
    add_reference :questions, :variant_of, foreign_key: { to_table: :questions, on_delete: :cascade },
      index: { unique: true }
    remove_index :questions, %i[clinical_case_id position], unique: true
    add_index :questions, %i[clinical_case_id position], unique: true, where: "variant_of_id IS NULL"
  end
end
