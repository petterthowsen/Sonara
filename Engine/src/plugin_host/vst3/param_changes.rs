//! Host-side `IParameterChanges` and `IParamValueQueue` with all queues and points
//! preallocated at construction, so handing them to `IAudioProcessor::process` never
//! allocates (the audio thread contract in AGENTS.md).
//!
//! Slots are created once and reused across blocks: `reset` clears the active queue count
//! and the points of every queue; `addParameterData` assigns an id to the next slot. The
//! raw `*mut IParamValueQueue` handed to the plugin stays valid for the lifetime of the
//! `ParameterChanges`, because the `ComWrapper` behind each slot lives in an `Arc` whose
//! allocation does not move.

use std::cell::{Cell, UnsafeCell};

use ::vst3::com_scrape_types::{ComPtr, ComWrapper};
use ::vst3::Class;
use ::vst3::Steinberg::Vst::{
    IParamValueQueue, IParamValueQueueTrait, IParameterChanges, IParameterChangesTrait, ParamID,
    ParamValue,
};
use ::vst3::Steinberg::{int32, kInvalidArgument, kResultFalse, kResultOk, tresult};

/// One parameter's ramp within a block: points are `(sample_offset, value)` pairs.
pub struct ParamValueQueue {
    id: Cell<ParamID>,
    points: UnsafeCell<Vec<(int32, ParamValue)>>,
    len: Cell<usize>,
}

impl ParamValueQueue {
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            id: Cell::new(0),
            points: UnsafeCell::new(vec![(0, 0.0); capacity]),
            len: Cell::new(0),
        }
    }

    pub fn capacity(&self) -> usize {
        unsafe { (*self.points.get()).len() }
    }

    pub fn len(&self) -> usize {
        self.len.get()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn id(&self) -> ParamID {
        self.id.get()
    }

    pub fn set_id(&self, id: ParamID) {
        self.id.set(id);
    }

    /// Drop all points; capacity is kept.
    pub fn reset(&self) {
        self.len.set(0);
    }

    /// Add a point, replacing an existing point at the same offset (VST3 semantics). Points
    /// stay in ascending offset order, as plugins expect. Returns false when the fixed
    /// capacity is exhausted.
    pub fn push(&self, sample_offset: int32, value: ParamValue) -> bool {
        let points = unsafe { &mut *self.points.get() };
        if let Some(point) = points[..self.len.get()]
            .iter_mut()
            .find(|(offset, _)| *offset == sample_offset)
        {
            point.1 = value;
            return true;
        }
        let len = self.len.get();
        if len >= points.len() {
            return false;
        }
        let position = points[..len].partition_point(|(offset, _)| *offset < sample_offset);
        points.copy_within(position..len, position + 1);
        points[position] = (sample_offset, value);
        self.len.set(len + 1);
        true
    }

    pub fn get(&self, index: usize) -> Option<(int32, ParamValue)> {
        if index >= self.len() {
            return None;
        }
        let points = unsafe { &*self.points.get() };
        Some(points[index])
    }
}

impl Class for ParamValueQueue {
    type Interfaces = (IParamValueQueue,);
}

impl IParamValueQueueTrait for ParamValueQueue {
    unsafe fn getParameterId(&self) -> ParamID {
        self.id.get()
    }

    unsafe fn getPointCount(&self) -> int32 {
        self.len.get() as int32
    }

    unsafe fn getPoint(
        &self,
        index: int32,
        sample_offset: *mut int32,
        value: *mut ParamValue,
    ) -> tresult {
        if index < 0 || sample_offset.is_null() || value.is_null() {
            return kInvalidArgument;
        }
        match self.get(index as usize) {
            Some((offset, point)) => {
                *sample_offset = offset;
                *value = point;
                kResultOk
            }
            None => kInvalidArgument,
        }
    }

    unsafe fn addPoint(
        &self,
        sample_offset: int32,
        value: ParamValue,
        index: *mut int32,
    ) -> tresult {
        let points = unsafe { &mut *self.points.get() };
        let len = self.len.get();
        // Replace an existing point at the same offset in place.
        if let Some(position) = points[..len]
            .iter()
            .position(|(offset, _)| *offset == sample_offset)
        {
            points[position].1 = value;
            if !index.is_null() {
                *index = position as int32;
            }
            return kResultOk;
        }
        if len >= points.len() {
            return kResultFalse;
        }
        points[len] = (sample_offset, value);
        self.len.set(len + 1);
        if !index.is_null() {
            *index = len as int32;
        }
        kResultOk
    }
}

struct QueueSlot {
    /// Keeps the COM object alive; its `Arc` allocation is stable, so the raw pointer below
    /// stays valid for as long as this struct exists.
    wrapper: ComWrapper<ParamValueQueue>,
    /// The owning reference for the interface pointer the plugin receives.
    ptr: ComPtr<IParamValueQueue>,
}

/// Fixed-capacity `IParameterChanges`: at most `capacity` parameters change per block, each
/// with up to `points_per_queue` points.
pub struct ParameterChanges {
    slots: UnsafeCell<Vec<QueueSlot>>,
    count: Cell<usize>,
}

impl ParameterChanges {
    pub fn new(capacity: usize, points_per_queue: usize) -> Self {
        let slots = (0..capacity)
            .map(|_| {
                let wrapper = ComWrapper::new(ParamValueQueue::with_capacity(points_per_queue));
                let ptr = wrapper.to_com_ptr::<IParamValueQueue>().unwrap();
                QueueSlot { wrapper, ptr }
            })
            .collect();
        Self {
            slots: UnsafeCell::new(slots),
            count: Cell::new(0),
        }
    }

    pub fn capacity(&self) -> usize {
        unsafe { (*self.slots.get()).len() }
    }

    /// Number of parameters with changes in the current block.
    pub fn len(&self) -> usize {
        self.count.get()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Start a new block: no active queues, no points.
    pub fn reset(&self) {
        self.count.set(0);
        for slot in unsafe { &*self.slots.get() } {
            slot.wrapper.reset();
        }
    }

    fn slot(&self, index: usize) -> Option<&QueueSlot> {
        let slots = unsafe { &*self.slots.get() };
        slots.get(index)
    }

    /// The queue for `id`, adding a slot if this is the first change for it in the block.
    /// Returns the queue and its index within the block.
    pub fn queue_for(&self, id: ParamID) -> Option<(&ComWrapper<ParamValueQueue>, usize)> {
        let count = self.count.get();
        for index in 0..count {
            let slot = self.slot(index)?;
            if slot.wrapper.id() == id {
                return Some((&slot.wrapper, index));
            }
        }
        let slot = self.slot(count)?;
        slot.wrapper.set_id(id);
        self.count.set(count + 1);
        Some((&slot.wrapper, count))
    }

    /// Queue `index` as the plugin sees it (used to read `outputParameterChanges`).
    pub fn queue(&self, index: usize) -> Option<&ComWrapper<ParamValueQueue>> {
        if index >= self.count.get() {
            return None;
        }
        self.slot(index).map(|slot| &slot.wrapper)
    }
}

impl Class for ParameterChanges {
    type Interfaces = (IParameterChanges,);
}

impl IParameterChangesTrait for ParameterChanges {
    unsafe fn getParameterCount(&self) -> int32 {
        self.count.get() as int32
    }

    unsafe fn getParameterData(&self, index: int32) -> *mut IParamValueQueue {
        if index < 0 || index as usize >= self.count.get() {
            return std::ptr::null_mut();
        }
        self.slot(index as usize)
            .map(|slot| slot.ptr.as_ptr())
            .unwrap_or(std::ptr::null_mut())
    }

    unsafe fn addParameterData(
        &self,
        id: *const ParamID,
        index: *mut int32,
    ) -> *mut IParamValueQueue {
        if id.is_null() {
            return std::ptr::null_mut();
        }
        match self.queue_for(*id) {
            Some((_, position)) => {
                if !index.is_null() {
                    *index = position as int32;
                }
                self.slot(position).unwrap().ptr.as_ptr()
            }
            None => {
                if !index.is_null() {
                    *index = -1;
                }
                std::ptr::null_mut()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ::vst3::ComRef;

    #[test]
    fn points_stay_in_ascending_offset_order() {
        let queue = ParamValueQueue::with_capacity(4);
        assert!(queue.push(30, 0.3));
        assert!(queue.push(10, 0.1));
        assert!(queue.push(20, 0.2));
        assert!(queue.push(10, 0.15)); // replaces
        assert!(queue.push(0, 0.0));
        assert!(!queue.push(40, 0.4)); // full
        let points: Vec<_> = (0..queue.len()).map(|i| queue.get(i).unwrap()).collect();
        assert_eq!(points, vec![(0, 0.0), (10, 0.15), (20, 0.2), (30, 0.3)]);
    }

    fn changes() -> (ComWrapper<ParameterChanges>, ComPtr<IParameterChanges>) {
        let wrapper = ComWrapper::new(ParameterChanges::new(2, 4));
        let ptr = wrapper.to_com_ptr::<IParameterChanges>().unwrap();
        (wrapper, ptr)
    }

    /// A non-owning view of a queue raw pointer; the slot in `ParameterChanges` owns the
    /// reference, so tests must not create owning `ComPtr`s from these pointers.
    unsafe fn borrow(queue: *mut IParamValueQueue) -> ComRef<'static, IParamValueQueue> {
        ComRef::from_raw(queue).unwrap()
    }

    #[test]
    fn add_and_read_back_points() {
        let (w, c) = changes();
        unsafe {
            let mut index = -1;
            let queue = c.addParameterData(&7, &mut index);
            assert!(!queue.is_null());
            assert_eq!(index, 0);
            let queue = borrow(queue);
            let mut point_index = -1;
            assert_eq!(queue.getParameterId(), 7);
            assert_eq!(queue.addPoint(128, 0.5, &mut point_index), 0);
            assert_eq!(point_index, 0);
            assert_eq!(queue.addPoint(0, 0.25, &mut point_index), 0);
            assert_eq!(point_index, 1);

            // Second parameter gets slot 1; the same parameter returns its existing slot.
            let queue_7_again = c.addParameterData(&7, &mut index);
            assert_eq!(index, 0);
            assert_eq!(queue_7_again, queue.as_ptr());
            let queue_9 = c.addParameterData(&9, &mut index);
            assert_eq!(index, 1);
            assert_ne!(queue_9, queue.as_ptr());
            assert_eq!(c.getParameterCount(), 2);

            // Reading the queues back through getParameterData.
            let q0 = borrow(c.getParameterData(0));
            let mut offset = -1;
            let mut value = -1.0;
            assert_eq!(q0.getPoint(0, &mut offset, &mut value), 0);
            assert_eq!((offset, value), (128, 0.5));
            assert_eq!(q0.getPoint(1, &mut offset, &mut value), 0);
            assert_eq!((offset, value), (0, 0.25));
            assert_eq!(q0.getPoint(2, &mut offset, &mut value), kInvalidArgument);

            let q1 = borrow(c.getParameterData(1));
            assert_eq!(q1.getParameterId(), 9);
            assert_eq!(q1.getPointCount(), 0);
        }
        assert_eq!(w.len(), 2);
    }

    #[test]
    fn reset_clears_queues_and_points() {
        let (w, c) = changes();
        unsafe {
            let mut index = -1;
            let queue = borrow(c.addParameterData(&3, &mut index));
            let mut point_index = -1;
            assert_eq!(queue.addPoint(0, 1.0, &mut point_index), 0);
        }
        w.reset();
        assert_eq!(w.len(), 0);
        unsafe {
            assert!(c.getParameterData(0).is_null());
            assert_eq!(c.getParameterCount(), 0);
        }
    }

    #[test]
    fn same_offset_replaces_point_and_overflow_refuses() {
        let (w, c) = changes();
        unsafe {
            let mut index = -1;
            let queue = borrow(c.addParameterData(&1, &mut index));
            let mut point_index = -1;
            assert_eq!(queue.addPoint(10, 0.1, &mut point_index), 0);
            assert_eq!(queue.addPoint(10, 0.9, &mut point_index), 0);
            assert_eq!(queue.getPointCount(), 1);
            let mut offset = -1;
            let mut value = -1.0;
            assert_eq!(queue.getPoint(0, &mut offset, &mut value), 0);
            assert_eq!((offset, value), (10, 0.9));

            // Capacity is 4 points; the 5th distinct offset is refused.
            for n in 0..3 {
                assert_eq!(queue.addPoint(20 + n as i32, 0.0, &mut point_index), 0);
            }
            assert_eq!(queue.addPoint(50, 0.0, &mut point_index), kResultFalse);
        }
        assert_eq!(w.capacity(), 2);
    }

    #[test]
    fn capacity_of_queues_refuses_extra_parameters() {
        let (_w, c) = changes();
        unsafe {
            let mut index = -1;
            assert!(!c.addParameterData(&1, &mut index).is_null());
            assert!(!c.addParameterData(&2, &mut index).is_null());
            assert!(c.addParameterData(&3, &mut index).is_null());
            assert_eq!(index, -1);
        }
    }
}
