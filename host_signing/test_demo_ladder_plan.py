import unittest

from demo_ladder_plan import select_next


def status(controller=11, edge1=9, edge2=9, tls=1, ota='valid'):
    return (f'role=0 version={controller} noise=1 tls={tls} '
            'edge1=192.168.4.2 edge2=192.168.4.3 '
            f'edge1_secure=v{edge1}_ota2_minheap212032_stack10844_rttms235 '
            f'edge2_secure=v{edge2}_ota2_minheap213612_stack10832_rttms341 '
            f'ota={ota} last_invalid=none heap=178952 minheap=168180 stack_margin=10772\n')


class DemoLadderTests(unittest.TestCase):
    def test_first_round_two_independent_role_images(self):
        self.assertEqual(select_next(status(), 'edge1'),
                         (1, 9, 10, 'edge1_reconnect_v10_demo', 'edge1'))
        self.assertEqual(select_next(status(), 'edge2'),
                         (2, 9, 10, 'edge2_reconnect_v10_demo', 'edge2'))

    def test_controller_last_each_round(self):
        with self.assertRaisesRegex(ValueError, 'Both edges'):
            select_next(status(edge1=10), 'controller')
        self.assertEqual(select_next(status(edge1=10, edge2=10), 'controller'),
                         (0, 11, 12, 'https_controller_v12_demo', 'update'))
        with self.assertRaisesRegex(ValueError, 'Both edges'):
            select_next(status(controller=12, edge1=11, edge2=10), 'controller')
        self.assertEqual(select_next(status(controller=12, edge1=11, edge2=11), 'controller')[2], 13)
        self.assertEqual(select_next(status(controller=13, edge1=12, edge2=12), 'controller')[2], 14)

    def test_staggered_edge_rounds(self):
        self.assertEqual(select_next(status(controller=12, edge1=10, edge2=11), 'edge1')[2], 11)
        self.assertEqual(select_next(status(controller=13, edge1=11, edge2=12), 'edge1')[2], 12)

    def test_ladder_exhausted(self):
        with self.assertRaisesRegex(ValueError, 'ends at v14'):
            select_next(status(controller=14, edge1=12, edge2=12), 'controller')
        with self.assertRaisesRegex(ValueError, 'ends at v12'):
            select_next(status(controller=14, edge1=12, edge2=12), 'edge1')

    def test_reject_unauthenticated_or_pending_status(self):
        with self.assertRaises(ValueError):
            select_next(status().replace('edge2_secure=v9_ota2_', 'edge2_secure=offline_'), 'edge1')
        with self.assertRaises(ValueError):
            select_next(status().replace('edge2_secure=v9_ota2_', 'edge2_secure=v9_ota1_'), 'edge1')
        with self.assertRaises(ValueError):
            select_next(status(ota='pending'), 'edge2')
        with self.assertRaises(ValueError):
            select_next(status(tls=0), 'edge1')

    def test_reject_unexpected_or_incomplete_versions(self):
        for state in (status(controller=8), status(edge2=30), status() + 'another line\n', 'role=0 version=11'):
            with self.subTest(state=state[:40]), self.assertRaises(ValueError):
                select_next(state, 'edge1')

    def test_reject_unknown_target(self):
        with self.assertRaises(ValueError):
            select_next(status(), 'edge3')


if __name__ == '__main__':
    unittest.main()
