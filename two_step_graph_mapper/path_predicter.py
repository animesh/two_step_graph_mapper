from pyvg.conversion import vg_json_file_to_interval_collection
from offsetbasedgraph import IntervalCollection, Interval
from collections import defaultdict
import logging


class PathPredicter:
    def __init__(self, alignment_file_name, graph, sequence_graph, chromosome, linear_interval_path,
                 out_file_base_name, linear_ref_bonus=1, max_nodes_to_traverse=None):
        self.alignment_file_name = alignment_file_name
        self.graph = graph
        self.sequence_graph = sequence_graph
        self.chromosome = chromosome
        self.linear_interval_path = linear_interval_path
        self.out_file_base_name = out_file_base_name
        self.linear_path_nodes = linear_interval_path.nodes_in_interval()
        self.linear_ref_bonus = linear_ref_bonus
        self.max_nodes_to_traverse = max_nodes_to_traverse
        self.alignments = None
        self._read_alignments()
        self.edge_counts = None
        self._get_edge_counts_from_alignments()
        self.predict_path()

    def _read_alignments(self):
        if self.alignment_file_name.endswith(".json"):
            self.alignments = vg_json_file_to_interval_collection(self.alignment_file_name).intervals
        elif self.alignment_file_name.endswith(".graphnodes"):
            self.alignments = (Interval(0, 1, [int(n) for n in line.strip().split()[1].split(",")])
                               for line in open(self.alignment_file_name))
        elif self.alignment_file_name.endswith(".graphalignments"):
            self.alignments = (Interval.from_file_line(line.strip().split("\t")[1]) for line in open(self.alignment_file_name) if line.strip().split("\t")[1] != ".")
        else:
            self.alignments = IntervalCollection.from_file(self.alignment_file_name).intervals

    def _get_edge_counts_from_alignments(self):
        edge_counts = defaultdict(int)
        graph_min_node = self.graph.blocks.node_id_offset - 1
        graph_max_node = self.graph.blocks.max_node_id()

        for alignment in self.alignments:
            if abs(alignment.region_paths[0]) < graph_min_node or abs(alignment.region_paths[0]) > graph_max_node:
                continue

            alignment.graph = self.graph
            if alignment.region_paths[0] < 0:
                alignment = alignment.get_reverse()


            prev_node = alignment.region_paths[0]
            for node in alignment.region_paths[1:]:
                edge_id = "%d-%d" % (prev_node, node)
                edge_counts[edge_id] += 1
                prev_node = node

        self.edge_counts = edge_counts

    def predict_path(self):
        logging.info("Using linear bonus %d on chromosome %s" % (self.linear_ref_bonus, self.chromosome))

        logging.info("Using linear out base name %s" % self.out_file_base_name)
        out_file = open("%s_%s.fasta" % (self.out_file_base_name, self.chromosome), "w")

        # Traverse
        first_nodes = self.graph.get_first_blocks()
        assert len(first_nodes) == 1

        logging.info("N nodes in graph: %d" % len(self.graph.blocks))

        node = first_nodes[0]
        assert node in self.linear_path_nodes, "Start node should be in linear ref"

        path = []
        n_ambigious = 0
        edges_chosen = set()
        i = 0
        n_special_case = 0
        while True:
            if i % 1000000 == 0:
                logging.info("%d nodes in graph traversed on chrom %s" % (i, self.chromosome))
            i += 1

            if self.max_nodes_to_traverse is not None and i > self.max_nodes_to_traverse:
                logging.warning("Stopped traversing before end because max node to traverse was set")
                break

            path.append(node)

            next_nodes = self.graph.adj_list[node]
            if len(next_nodes) == 0:
                logging.info("Done on node %d" % node)
                break
            elif len(next_nodes) == 1:
                node = next_nodes[0]
            else:
                most_reads = 0
                most_reads_node = next_nodes[0]
                has_found_candidate_on_linear_ref = False

                for next_node in next_nodes:
                    n_reads = self.edge_counts["%s-%s" % (node, next_node)]
                    if next_node in self.linear_path_nodes:
                        n_reads += self.linear_ref_bonus

                    if n_reads > most_reads or (n_reads >= most_reads and next_node in self.linear_path_nodes):
                        if node not in self.linear_path_nodes:
                            n_special_case += 1

                        # If already found something on linear ref, and this does not have more reads or lower id (not insertion), ignore
                        if has_found_candidate_on_linear_ref and n_reads == most_reads and next_node > most_reads_node:
                            continue  # Ignore this alternative

                        most_reads_node = next_node
                        most_reads = n_reads

                        if next_node in self.linear_path_nodes:
                            has_found_candidate_on_linear_ref = True

                if most_reads == 0:
                    n_ambigious += 1

                assert most_reads_node is not None

                edges_chosen.add("%d-%d" % (node, most_reads_node))
                node = most_reads_node

                if most_reads == 0:
                    # Assert we have taken linear ref path if exists
                    if any([n in self.linear_path_nodes for n in next_nodes]):
                        if node not in self.linear_path_nodes:
                            logging.error("Chose node %d as next, but it is not in linear ref." % node)
                            logging.error("Next nodes are: %s" % next_nodes)

                            for next_node in next_nodes:
                                if next_node in self.linear_path_nodes:
                                    logging.error("    Node %d is in linear ref" % next_node)
                                else:
                                    logging.error("    Node %d is not in linear ref" % next_node)

                            raise Exception("Could not traverse correctly")

        # Find statistics of chosen nodes
        nodes_chosen = set(path)
        n_on_linear = len(nodes_chosen.intersection(self.linear_path_nodes))
        n_not_on_linear = len(nodes_chosen) - n_on_linear

        linear_ref_interval = Interval(0, self.graph.blocks[path[-1]].length(), path, self.graph)
        IntervalCollection([linear_ref_interval]).to_file("%s_%s.intervalcollection" % (self.out_file_base_name, self.chromosome),
                                                          text_file=True)

        logging.info("=== STATS FOR CHROMOSOME %s ===" % self.chromosome)
        logging.info("N ambigious choices: %d" % n_ambigious)
        logging.info("Total nodes in linear ref: %d" % len(self.linear_path_nodes))
        logging.info("N nodes chosen that are not in linear ref: %d " % n_not_on_linear)
        logging.info("N nodes chosen that are in linear ref: %d " % n_on_linear)
        logging.info("N special case: %d" % n_special_case)
        logging.info("N nodes in path: %d" % len(path))
        logging.info("Linear path length: %d" % linear_ref_interval.length())

        sequence = self.sequence_graph.get_interval_sequence(linear_ref_interval)

        out_file.writelines([">%s\n" % self.chromosome])
        out_file.writelines([sequence + "\n"])
        out_file.close()

