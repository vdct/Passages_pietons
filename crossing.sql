DROP TABLE IF EXISTS crossing CASCADE;
CREATE TABLE crossing
(
	objectid		serial,
	id_origine		character varying(50),
	incidents		smallint,
	angle			smallint,
	geometrie		geometry,
	osm_highway		character varying (150)
)
WITH (OIDS=TRUE);

CREATE INDEX gidx_crossing ON crossing USING GIST(geometrie);

DROP TABLE IF EXISTS tmp_crossing CASCADE;
CREATE TABLE tmp_crossing
AS
SELECT	osm_id,
	highway,
	way geom
FROM planet_osm_point
WHERE highway = 'crossing';

DROP TABLE IF EXISTS tmp_ways_crossing CASCADE;
CREATE TABLE tmp_ways_crossing
AS
SELECT 	f.id way_id,
	unnest(f.nodes) node,
	p2.longueur
FROM	planet_osm_ways f
JOIN 	(
		SELECT DISTINCT id
		FROM 	(
				SELECT	osm_id
				FROM	tmp_crossing
			) b 
		JOIN	(
				SELECT id,
					unnest(nodes) n
				FROM 	planet_osm_ways
				WHERE 	'highway' = any(tags)
			) w
		ON	b.osm_id = w.n
	) j
ON	f.id = j.id
JOIN	(
		SELECT 	wid,
			count(*) longueur
		FROM	(
				(
					SELECT id wid,
						unnest(nodes) node
					FROM	planet_osm_ways w
				)p0
				JOIN	planet_osm_nodes n
				ON	n.id = p0.node
			)p1
		GROUP BY wid
	)p2
ON	p2.wid = f.id
LEFT OUTER JOIN planet_osm_polygon p
ON	f.id = p.osm_id
WHERE	p.osm_id IS NULL;

ALTER TABLE tmp_ways_crossing ADD COLUMN "order" serial;

DROP TABLE IF EXISTS tmp_ways_nodes_rang CASCADE;
CREATE TABLE tmp_ways_nodes_rang
AS
SELECT 	t.way_id,
	t.node,
	t.longueur,
	rank() over(partition by t.way_id order by t."order") rang,
	ST_SetSRID(ST_MakePoint(n.lon::decimal/10000000,n.lat::decimal/10000000),4326) geom
FROM	tmp_ways_crossing t
JOIN	planet_osm_nodes n
ON	t.node = n.id;

DROP TABLE IF EXISTS tmp_nodes_encadrant CASCADE;
CREATE TABLE tmp_nodes_encadrant
AS
SELECT 	m.way_id,
	m.node,
	m.rang,
	rank() over(partition by m.node order by m.way_id,m.rang) 		mini,
	rank() over(partition by m.node order by m.way_id desc,m.rang desc)maxi
FROM	(
		SELECT 	way_id,
			node,
			rang-1	rang
		FROM tmp_ways_nodes_rang
		JOIN tmp_crossing
		ON node = osm_id
		WHERE rang > 1 
		UNION
		SELECT 	way_id,
			node,
			rang+1
		FROM tmp_ways_nodes_rang
		JOIN tmp_crossing
		ON node = osm_id
		WHERE rang < longueur
	) m;

ALTER TABLE tmp_nodes_encadrant ADD COLUMN "order" serial;

TRUNCATE crossing;

-- Barrières sur cul de sac
INSERT INTO crossing(id_origine,
			incidents,
			angle,
			osm_highway,
			geometrie)
SELECT	id_crossing::text,
	1,
	(ST_azimuth(geom_crossing,geom_node_apres)/(2*pi()))*360,
	highway,
	geom_crossing
FROM	(
		SELECT	n.node id_crossing,
			g.highway,
			g.geom geom_crossing,
			nf.geom geom_node_apres,
			ns.way_id,
			ns.rang
		FROM
			(
			SELECT	node
			FROM 	tmp_nodes_encadrant
			GROUP BY 1
			HAVING	count(*) = 1
			) n
		JOIN	tmp_crossing g
		ON	n.node = g.osm_id
		JOIN	tmp_nodes_encadrant ns
		ON	n.node = ns.node	AND
			ns.maxi = 1
		JOIN	tmp_ways_nodes_rang nf
		ON	ns.way_id = nf.way_id	AND
			ns.rang = nf.rang
	)a;

-- Barrière sur un seul axe
INSERT INTO crossing(id_origine,
			incidents,
			angle,
			osm_highway,
			geometrie)
SELECT	id_crossing::text,
	2,
	(ST_azimuth(geom_crossing,geom_node_avant)+ST_azimuth(geom_crossing,geom_node_apres))/(2*pi())*180,
	highway,
	geom_crossing
FROM	(
		SELECT	n.node id_crossing,
			g.highway,
			g.geom geom_crossing,
			nd.geom geom_node_avant,
			nf.geom geom_node_apres
		FROM
			(
			SELECT	node
			FROM 	tmp_nodes_encadrant
			GROUP BY 1
			HAVING	count(*) = 2
			) n
		JOIN	tmp_crossing g
		ON	n.node = g.osm_id
		JOIN	tmp_nodes_encadrant np
		ON	n.node = np.node	AND
			np.mini = 1
		JOIN	tmp_nodes_encadrant ns
		ON	n.node = ns.node	AND
			ns.maxi = 1
		JOIN	tmp_ways_nodes_rang nd
		ON	np.way_id = nd.way_id	AND
			np.rang = nd.rang
		JOIN	tmp_ways_nodes_rang nf
		ON	ns.way_id = nf.way_id	AND
			ns.rang = nf.rang
	)a;

-- Barrière sur carrefour incident à + de 2 tronçons
INSERT INTO crossing(id_origine,
			incidents,
			angle,
			osm_highway,
			geometrie)
SELECT	id_crossing::text,
	3,
	0,
	highway,
	geom_crossing
FROM	(
		SELECT	n.node id_crossing,
			g.highway,
			g.geom geom_crossing
		FROM
			(
				SELECT	node
				FROM 	tmp_nodes_encadrant
				GROUP BY 1
				HAVING	count(*) > 2
			) n
		JOIN	tmp_crossing g
		ON	n.node = g.osm_id
	)a;

-- Ménage
/*DROP TABLE IF EXISTS tmp_barriers CASCADE;
DROP TABLE IF EXISTS tmp_ways_barriers CASCADE;
DROP TABLE IF EXISTS tmp_ways_nodes_rang CASCADE;
DROP TABLE IF EXISTS tmp_nodes_encadrant CASCADE;
*/