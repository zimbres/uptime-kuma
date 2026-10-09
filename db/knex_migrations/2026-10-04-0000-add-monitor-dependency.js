exports.up = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.integer("dependency").unsigned().nullable().defaultTo(null)
            .references("id").inTable("monitor")
            .onDelete("SET NULL").onUpdate("CASCADE");
    });
};

exports.down = function (knex) {
    return knex.schema.alterTable("monitor", function (table) {
        table.dropColumn("dependency");
    });
};