-- Tree Migration Script: Copy nodes and data_sources from 'src' to 'dst' database
-- Grafts the source tree under a specified parent node in destination
--
-- Prerequisites:
-- 1. Both databases exist in the same PostgreSQL instance
-- 2. Current connection is to the 'dst' database
-- 3. User has appropriate permissions on both databases
-- 4. Tables: nodes(id, parent_id, ...), node_closure(ancestor_id, descendant_id, depth)
--           data_sources(id, node_id, ...)

-- =============================================================================
-- CONFIGURATION
-- =============================================================================

-- Set the parent node ID in destination database where source tree will be grafted
-- Change this value as needed
\set graft_parent_id 1

-- =============================================================================
-- SETUP FOREIGN DATA WRAPPER
-- =============================================================================

-- Create FDW connection to source database
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Drop existing server if it exists (for re-runs)
DROP SERVER IF EXISTS src_server CASCADE;

CREATE SERVER src_server
FOREIGN DATA WRAPPER postgres_fdw
OPTIONS (host 'localhost', port '5432', dbname 'src');

-- Create user mapping - adjust username as needed
CREATE USER MAPPING FOR postgres
SERVER src_server
OPTIONS (user 'postgres', password 'secret');

-- Import foreign schema
DROP SCHEMA IF EXISTS foreign_src CASCADE;
CREATE SCHEMA foreign_src;

IMPORT FOREIGN SCHEMA public 
FROM SERVER src_server 
INTO foreign_src;

-- =============================================================================
-- ID MAPPING PREPARATION
-- =============================================================================

-- Get ID offsets to avoid collisions
DO $$
DECLARE
    max_node_id BIGINT;
    max_data_source_id BIGINT;
    graft_parent_id BIGINT := 1;  -- Set your graft parent ID here
BEGIN
    -- Get current max IDs in destination
    SELECT COALESCE(MAX(id), 0) INTO max_node_id FROM nodes;
    SELECT COALESCE(MAX(id), 0) INTO max_data_source_id FROM data_sources;
    
    RAISE NOTICE 'Current max node id in dst: %, max data_source id: %', 
                 max_node_id, max_data_source_id;
    
    -- Store as session variables for later use
    PERFORM set_config('migration.node_offset', max_node_id::text, false);
    PERFORM set_config('migration.data_source_offset', max_data_source_id::text, false);
    PERFORM set_config('migration.graft_parent_id', graft_parent_id::text, false);
END $$;

-- Create ID mapping tables
DROP TABLE IF EXISTS node_id_mapping;
CREATE TEMPORARY TABLE node_id_mapping (
    old_id BIGINT PRIMARY KEY,
    new_id BIGINT NOT NULL,
    new_parent_id BIGINT,
    UNIQUE(new_id)
);

DROP TABLE IF EXISTS data_source_id_mapping;
CREATE TEMPORARY TABLE data_source_id_mapping (
    old_id BIGINT PRIMARY KEY,
    new_id BIGINT NOT NULL,
    UNIQUE(new_id)
);

-- =============================================================================
-- BUILD ID MAPPINGS
-- =============================================================================

-- Map node IDs with parent relationship handling
INSERT INTO node_id_mapping (old_id, new_id, new_parent_id)
WITH 
offsets AS (
    SELECT 
        current_setting('migration.node_offset')::BIGINT as node_offset,
        current_setting('migration.graft_parent_id')::BIGINT as graft_parent_id
),
roots_in_src AS (
    SELECT id as old_id FROM foreign_src.nodes WHERE parent_id IS NULL
),
mapped_nodes AS (
    SELECT 
        n.id as old_id,
        n.id + o.node_offset as new_id,
        CASE 
            WHEN r.old_id IS NOT NULL THEN o.graft_parent_id  -- Root nodes get graft parent
            ELSE n.parent + o.node_offset                  -- Other nodes get mapped parent
        END as new_parent_id
    FROM foreign_src.nodes n
    LEFT JOIN roots_in_src r ON n.id = r.old_id
    CROSS JOIN offsets o
)
SELECT old_id, new_id, new_parent_id FROM mapped_nodes;

-- Map data_source IDs
INSERT INTO data_source_id_mapping (old_id, new_id)
SELECT 
    ds.id,
    ds.id + current_setting('migration.data_source_offset')::BIGINT
FROM foreign_src.data_sources ds;

-- Show mapping summary
DO $$
DECLARE
    node_count INT;
    data_source_count INT;
    root_count INT;
    graft_parent_id BIGINT := current_setting('migration.graft_parent_id')::BIGINT;
BEGIN
    SELECT COUNT(*) INTO node_count FROM node_id_mapping;
    SELECT COUNT(*) INTO data_source_count FROM data_source_id_mapping;
    SELECT COUNT(*) INTO root_count FROM node_id_mapping WHERE new_parent_id = graft_parent_id;
    
    RAISE NOTICE 'Created mappings: % nodes (% roots), % data_sources', 
                 node_count, root_count, data_source_count;
END $$;

-- =============================================================================
-- VALIDATE GRAFT POINT
-- =============================================================================

DO $$
DECLARE
    graft_parent_id BIGINT := current_setting('migration.graft_parent_id')::BIGINT;
BEGIN
    -- Check that graft parent exists in destination
    IF NOT EXISTS (SELECT 1 FROM nodes WHERE id = graft_parent_id) THEN
        RAISE EXCEPTION 'Graft parent node id % does not exist in destination database', graft_parent_id;
    END IF;
    
    RAISE NOTICE 'Graft parent node id % validated', graft_parent_id;
END $$;

-- =============================================================================
-- MIGRATE NODES (HIERARCHICAL ORDER)
-- =============================================================================

-- Begin migration transaction
BEGIN;

DO $$
BEGIN
    RAISE NOTICE 'Starting hierarchical node migration...';
END $$;

-- Insert nodes in parent-first order using recursive CTE
WITH RECURSIVE insert_order AS (
    -- Start with root nodes (being grafted to existing tree)
    SELECT 
        m.old_id, 
        m.new_id, 
        m.new_parent_id, 
        1 as level,
        ARRAY[m.old_id] as path
    FROM node_id_mapping m 
    WHERE m.new_parent_id = current_setting('migration.graft_parent_id')::BIGINT
    
    UNION ALL
    
    -- Add children level by level
    SELECT 
        m.old_id, 
        m.new_id, 
        m.new_parent_id,
        io.level + 1,
        io.path || m.old_id
    FROM node_id_mapping m
    JOIN foreign_src.nodes n ON n.id = m.old_id
    JOIN insert_order io ON n.parent = io.old_id
    WHERE NOT m.old_id = ANY(io.path)  -- Prevent infinite recursion on cycles
),
ordered_nodes AS (
    SELECT DISTINCT
        o.old_id, o.new_id, o.new_parent_id, o.level
    FROM insert_order o
    ORDER BY o.level, o.new_id
)
INSERT INTO nodes (id, parent_id, name, description, created_at)
SELECT 
    o.new_id,
    o.new_parent_id, 
    n.name,
    n.description,
    n.created_at
FROM ordered_nodes o
JOIN foreign_src.nodes n ON n.id = o.old_id
ORDER BY o.level, o.new_id;

-- Get migration stats
DO $$
DECLARE
    inserted_count INT;
BEGIN
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RAISE NOTICE 'Inserted % nodes', inserted_count;
END $$;

-- =============================================================================
-- MIGRATE DATA_SOURCES
-- =============================================================================

DO $$
BEGIN
    RAISE NOTICE 'Migrating data_sources...';
END $$;

INSERT INTO data_sources (id, node_id, source_type, connection_string, created_at)
SELECT 
    dsm.new_id,
    nm.new_id,
    ds.source_type,
    ds.connection_string,
    ds.created_at
FROM foreign_src.data_sources ds
JOIN data_source_id_mapping dsm ON ds.id = dsm.old_id
JOIN node_id_mapping nm ON ds.node_id = nm.old_id;

-- Get migration stats
DO $$
DECLARE
    inserted_count INT;
BEGIN
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RAISE NOTICE 'Inserted % data_sources', inserted_count;
END $$;

-- =============================================================================
-- VALIDATION
-- =============================================================================

DO $$
BEGIN
    RAISE NOTICE 'Running validation checks...';
END $$;

-- Check referential integrity
DO $$
DECLARE
    orphaned_nodes INT;
    orphaned_data_sources INT;
    graft_parent_id BIGINT := current_setting('migration.graft_parent_id')::BIGINT;
BEGIN
    -- Check for orphaned nodes (should be 0, except for nodes with graft_parent_id as parent)
    SELECT COUNT(*) INTO orphaned_nodes
    FROM nodes n 
    LEFT JOIN nodes p ON n.parent = p.id 
    WHERE n.id IN (SELECT new_id FROM node_id_mapping)
      AND p.id IS NULL 
      AND n.parent != graft_parent_id;
    
    -- Check for orphaned data_sources (should be 0)  
    SELECT COUNT(*) INTO orphaned_data_sources
    FROM data_sources ds 
    LEFT JOIN nodes n ON ds.node_id = n.id 
    WHERE ds.id IN (SELECT new_id FROM data_source_id_mapping)
      AND n.id IS NULL;
    
    IF orphaned_nodes > 0 THEN
        RAISE EXCEPTION 'Found % orphaned nodes - referential integrity violated', orphaned_nodes;
    END IF;
    
    IF orphaned_data_sources > 0 THEN
        RAISE EXCEPTION 'Found % orphaned data_sources - referential integrity violated', orphaned_data_sources;
    END IF;
    
    RAISE NOTICE 'Validation passed: no orphaned records found';
END $$;

-- Check closure table integrity (if triggers maintained it correctly)
DO $$
DECLARE
    missing_closure_entries INT;
BEGIN
    -- This is a basic check - you might want more sophisticated validation
    SELECT COUNT(*) INTO missing_closure_entries
    FROM node_id_mapping nm
    LEFT JOIN node_closure nc ON nc.descendant_id = nm.new_id
    WHERE nc.descendant_id IS NULL;
    
    IF missing_closure_entries > 0 THEN
        RAISE WARNING 'Found % nodes missing closure table entries - triggers may not have fired correctly', 
                      missing_closure_entries;
    ELSE
        RAISE NOTICE 'Closure table validation passed';
    END IF;
END $$;

-- =============================================================================
-- CLEANUP AND SUMMARY
-- =============================================================================

-- Final summary
DO $$
DECLARE
    total_nodes INT;
    total_data_sources INT;
    tree_depth INT;
    graft_parent_id BIGINT := current_setting('migration.graft_parent_id')::BIGINT;
BEGIN
    SELECT COUNT(*) INTO total_nodes FROM node_id_mapping;
    SELECT COUNT(*) INTO total_data_sources FROM data_source_id_mapping;
    
    -- Get depth of migrated tree
    SELECT MAX(depth) INTO tree_depth 
    FROM nodes_closure nc
    JOIN node_id_mapping nm ON nc.descendant = nm.new_id
    WHERE nc.ancestor = graft_parent_id;
    
    RAISE NOTICE '=== MIGRATION COMPLETED ===';
    RAISE NOTICE 'Migrated % nodes and % data_sources', total_nodes, total_data_sources;
    RAISE NOTICE 'Tree grafted under node id % with max depth %', graft_parent_id, COALESCE(tree_depth, 0);
    RAISE NOTICE 'New node id range: % to %', 
                 (SELECT MIN(new_id) FROM node_id_mapping),
                 (SELECT MAX(new_id) FROM node_id_mapping);
    RAISE NOTICE 'New data_source id range: % to %',
                 (SELECT MIN(new_id) FROM data_source_id_mapping),
                 (SELECT MAX(new_id) FROM data_source_id_mapping);
END $$;

-- Commit the migration
COMMIT;

-- Cleanup FDW (optional - comment out if you want to keep it)
-- DROP SERVER src_server CASCADE;

DO $$
BEGIN
    RAISE NOTICE 'Migration transaction committed successfully!';
END $$;
