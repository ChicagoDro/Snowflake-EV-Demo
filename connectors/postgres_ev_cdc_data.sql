-- PostgreSQL DDL and seed data for EV Demo CDC replication (run in psql, not Snowflake)
-- Co-authored with CoCo

-- Connect as your admin user
CREATE DATABASE ev_reference;
\c ev_reference

-- DYNAMIC operational table — this is the CDC target
-- Status changes daily as the state processes incentive applications
CREATE TABLE public.incentive_applications (
    application_id      SERIAL PRIMARY KEY,
    vin                 VARCHAR(17) NOT NULL,
    submitted_date      DATE NOT NULL,
    applicant_zip       VARCHAR(10) NOT NULL,
    vehicle_type        VARCHAR(50),  -- 'BEV' or 'PHEV'
    make                VARCHAR(50),
    model               VARCHAR(100),
    model_year          INTEGER,
    incentive_amount    NUMERIC(10,2),
    status              VARCHAR(20) DEFAULT 'PENDING',  -- PENDING, APPROVED, DENIED
    reviewed_date       DATE,
    denial_reason       VARCHAR(200),
    updated_at          TIMESTAMP DEFAULT NOW()
);

-- Seed incentive_applications with realistic WA data (daily-changing operational data)
-- VINs reference actual registered vehicles from the WA DOL registration dataset
INSERT INTO public.incentive_applications (vin, submitted_date, applicant_zip, vehicle_type, make, model, model_year, incentive_amount, status, reviewed_date, denial_reason) VALUES
('5YJ3E1EB4N', '2026-06-01', '98101', 'BEV', 'TESLA', 'MODEL 3', 2022, 7500.00, 'APPROVED', '2026-06-05', NULL),
('7FCTGAAA9N', '2026-06-02', '98052', 'BEV', 'RIVIAN', 'R1T', 2022, 7500.00, 'APPROVED', '2026-06-06', NULL),
('JTMEB3FVXM', '2026-06-03', '98004', 'PHEV', 'TOYOTA', 'RAV4 PRIME', 2021, 4000.00, 'APPROVED', '2026-06-08', NULL),
('1G1FX6S01P', '2026-06-05', '98033', 'BEV', 'CHEVROLET', 'BOLT EV', 2023, 7500.00, 'PENDING', NULL, NULL),
('KM8KNDAF4N', '2026-06-07', '98115', 'BEV', 'HYUNDAI', 'IONIQ 5', 2022, 7500.00, 'PENDING', NULL, NULL),
('3FMTK3SU1N', '2026-06-08', '98802', 'BEV', 'FORD', 'MUSTANG MACH-E', 2022, 7500.00, 'DENIED', '2026-06-12', 'Income exceeds threshold'),
('WBA5U9Z0CP', '2026-06-10', '98074', 'PHEV', 'BMW', 'X5 XDRIVE50E', 2023, 4000.00, 'DENIED', '2026-06-14', 'MSRP exceeds cap'),
('5YJ3E1EB3N', '2026-06-12', '98101', 'BEV', 'TESLA', 'MODEL 3', 2022, 7500.00, 'APPROVED', '2026-06-16', NULL),
('5YJY9DGEYP', '2026-06-15', '98103', 'BEV', 'TESLA', 'MODEL Y', 2023, 7500.00, 'PENDING', NULL, NULL),
('KNDC4DLC5P', '2026-06-18', '98001', 'BEV', 'KIA', 'EV6', 2023, 7500.00, 'PENDING', NULL, NULL),
('1C4JJXP6XM', '2026-06-20', '98362', 'PHEV', 'JEEP', 'WRANGLER 4XE', 2021, 4000.00, 'PENDING', NULL, NULL),
('4JGDM2EB5P', '2026-06-22', '98199', 'BEV', 'MERCEDES-BENZ', 'EQS-CLASS SUV', 2023, 7500.00, 'DENIED', '2026-06-26', 'MSRP exceeds cap'),
('1V2GNPE84P', '2026-07-01', '98034', 'BEV', 'VOLKSWAGEN', 'ID.4', 2023, 7500.00, 'APPROVED', '2026-07-05', NULL),
('LPSED3KA2N', '2026-07-03', '98005', 'BEV', 'POLESTAR', '2', 2022, 7500.00, 'PENDING', NULL, NULL),
('JTMABABA9P', '2026-07-10', '99336', 'BEV', 'SUBARU', 'SOLTERRA', 2023, 7500.00, 'PENDING', NULL, NULL);

-- Create publication for CDC (Snowflake connector reads WAL changes from this)
CREATE PUBLICATION snowflake_pub FOR TABLE public.incentive_applications;

-- Create dedicated replication user
CREATE USER snowflake_replicator WITH PASSWORD '<secure_password>' REPLICATION;
GRANT CONNECT ON DATABASE ev_reference TO snowflake_replicator;
GRANT USAGE ON SCHEMA public TO snowflake_replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO snowflake_replicator;
