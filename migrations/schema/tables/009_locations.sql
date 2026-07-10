/*=====================================================================
  009_locations.sql — PostgreSQL conversion of HRMS.LOCATIONS
  Source: ts-plsql-oracle-forms-hrms/schema/tables/01_core_tables.sql

  Conversions applied:
    - VARCHAR2(n)        -> varchar(n)
    - CHAR(1)            -> char(1)
    - DATE DEFAULT SYSDATE -> timestamptz DEFAULT now()
=====================================================================*/

CREATE SCHEMA IF NOT EXISTS "$(NS)";

CREATE TABLE "$(NS)".locations (
    location_code varchar(10) NOT NULL,
    location_name varchar(100) NOT NULL,
    address_line1 varchar(200),
    address_line2 varchar(200),
    city varchar(100),
    state_province varchar(100),
    postal_code varchar(20),
    country_code varchar(3),
    phone_number varchar(30),
    timezone varchar(50) DEFAULT 'America/New_York',
    active_flag char(1) DEFAULT 'Y' NOT NULL,
    created_by varchar(30),
    created_date timestamptz DEFAULT now() NOT NULL,
    modified_by varchar(30),
    modified_date timestamptz,
    CONSTRAINT pk_locations PRIMARY KEY (location_code),
    CONSTRAINT chk_location_active CHECK (active_flag IN ('Y', 'N'))
);
